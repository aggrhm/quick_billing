module QuickBilling

  module Subscription

    STATES = {inactive: 1, active: 2, cancelled: 3, created: 4}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_subscription_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :pi, as: :period_interval, type: Integer, default: 1   # period in months
          field :pu, as: :period_unit, type: String, default: 'month'   # period in months
          field :p_st, as: :period_start, type: Time
          field :p_end, as: :period_end, type: Time
          field :li_id, as: :last_invoice_id
          field :ar, as: :is_autorenewable, type: Boolean, default: true
          field :pr, as: :is_prorateable, type: Boolean, default: false
          field :ia, as: :invoiceable_amount, type: Integer

          belongs_to :account, :foreign_key => :aid, :class_name => QuickBilling.Account.to_s
          has_many :entries, :class_name => QuickBilling.Entry.to_s, :dependent => :destroy

          mongoid_timestamps!

          enum_methods! :state, STATES

          scope :active, lambda {
            where(st: STATES[:active])
          }
          scope :expired, lambda {
            where(:p_end => {'$lt' => Time.now})
          }
          scope :for_account, lambda {|aid|
            where(aid: aid)
          }
        end

      end

      def build_subscription(account, base_entries, opts={})
        # prepare subscription
        sub = self.new
        sub.account = account
        sub.state! :created
        sub.is_autorenewable = true
        sub.period_interval = 1
        sub.period_unit = 'month'
        sub.period_start = Time.now
        sub.period_end = Time.now + sub.period_length

        # prepare entries
        entries = sub.invoiceable_entries
        base_entries.each do |entry|
          if entry["source"] == QuickBilling::Entry::SOURCES[:product]
            product = QuickBilling.Product.find(entry["id"])
            if product.nil? || !product.is_available? || product.period_length_hash != sub.period_length_hash
              return {success: false, data: sub, error: "Plan not available"}
            end
            next if entries.any?{|en| en.product_id == product.id}
            e = QuickBilling.Entry.build_from_product(product, entry["quantity"].to_i)
          elsif entry["source"] == QuickBilling::Entry::SOURCES[:discount]
            coupon = QuickBilling.Coupon.find_with_code(entry["code"])
            if coupon.nil? || !coupon.redeemable_by_account?(account.id) || !coupon.style?(:subscription)
              return {success: false, data: sub, error: "Coupon code is invalid"}
            end
            next if entries.any?{|en| en.coupon_id == coupon.id}
            e = QuickBilling.Entry.build_from_coupon(coupon)
          end
          if !e.valid?
            return {success: false, data: sub, error: "Subscription entry invalid"}
          end
          entries << e
        end

        inv = sub.build_invoice
        if opts[:start] != true && opts[:start] != "true"
          return {success: true, data: sub}
        end

        # ensure credit card if amount is positive
        if inv.total > 0 && !sub.account.has_valid_payment_method?
          return {success: false, data: sub, error: "Billing account for this subscription must have a valid payment method"}
        end

        # commit everything
        if !sub.valid?
          return {success: false, data: sub, error: sub.errors.values.flatten[0]}
        end

        sub.save!
        entries.each do |entry|
          entry.subscription = sub
          entry.account = sub.account
          entry.save!
        end

        # enter charge
        result = sub.renew!
        return {success: false, data: sub, error: result[:error]} if result[:success] == false

        Job.run_later :billing, sub, :handle_activated
        return {success: true, data: sub}
      end

      def process_expired_subscriptions(opts={})
        self.active.expired.each do |sub|
          Rails.logger.info "#{Time.now.to_s} : Adding job for expired subscription."
          if sub.is_autorenewable == true
            Job.run_later :billing, sub, :renew!
          else
            Job.run_later :billing, sub, :cancel!
          end
        end
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS

    def product_entries
      self.invoiceable_entries.select{|e| e.source? :product }
    end

    def last_invoice
      @last_invoice ||= QuickBilling.Invoice.find(self.last_invoice_id)
    end

    def invoiceable_entries
      @invoiceable_entries ||= QuickBilling.Entry.for_subscription(self.id).invoiceable.to_a
    end
    def invoiceable_entries=(val)
      @invoiceable_entries=(val)
    end

    def expired?
      return false if self.period_end.nil?
      self.period_end < Time.now
    end

    def period_length
      case self.period_unit
      when 'month'
        return self.period_interval.months
      when 'year'
        return self.period_interval.years
      else
        return nil
      end
    end

    def period_length_hash
      {interval: self.period_interval, unit: self.period_unit}
    end

    # TRANSACTIONS

    def build_invoice
      entries = self.invoiceable_entries
      inv = QuickBilling.Invoice.new
      inv.subscription = self
      inv.account = self.account
      inv.description = "Subscription Billing Invoice"
      inv.state! :open
      inv.period_start = self.period_start
      inv.period_end = self.period_end
      inv.parse_entries(entries)
      self.invoiceable_amount = inv.total
      return inv
    end

    def renew!
      if self.state?(:active) && !self.expired?
        return {success: false, error: "Cannot renew this subscripton because it has more time left."}
      end

      inv = self.build_invoice
      resp = inv.charge_to_account!(self.account)

      begin
        if resp[:success]
          self.period_start = self.period_end || Time.now
          self.period_end = self.period_start + self.period_length
          self.last_invoice_id = inv.id
          self.state! :active
          self.save
          Job.run_later :billing, self, :handle_renewed
          return {success: true}
        else
          return {success: false, error: "Could not build invoice for Subscription"}
        end
      rescue
        inv.void!
        self.state! :inactive
        self.save
        return {success: false, error: "An error occurred processing the Invoice"}
      end
    end

    def cancel!
      exp = self.period_end

      # issue credit
      if self.state?(:active) && exp > Time.now && self.last_charged_amount > 0
        time_rem = exp - Time.now
        time_rem_f = time_rem / (exp - self.last_charged_at)
        credit_due = (time_rem_f * self.last_charged_amount).to_i
        result = QuickBilling.Transaction.enter_credit!(self.account, credit_due, {description: 'Subscription cancellation credit', subscription: self})
        return {success: false, error: 'Could not issue credit for cancellation.'} if result[:success] == false
      end

      # cancel subscription
      self.period_end = Time.now
      self.state! :cancelled
      self.save

      # update balance
      Job.run_later :billing, self, :handle_cancelled
      return {success: true}
    end

    def update_plan!(opts)
      # TODO: allow update plan or quantity, cancel or prorate subscription
    end

    def add_coupon(coupon)

      e = QuickBilling.Entry.new
      e.source! :discount
      e.coupon = coupon
      e.name = "Coupon"
      e.amount = coupon.amount
      e.percent = coupon.percent
      e.periods_left = coupon.max_uses
      e.subscription = self
      e.account = self.account
      if self.entries.select{|entry| entry.coupon.id.to_s == coupon.id.to_s}.length > 0
        return {success: false, error: "Coupon code already added"}
      end
      if !coupon.style?(:subscription)
        return {success: false, error: "Coupon is not for subscriptions"}
      end
      if e.save
        return {success: true, data: e}
      else
        return {success: false, error: e.error_message}
      end
    end

    def handle_activated
    end
    def handle_renewed
    end
    def handle_cancelled
    end

    # API

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:period_start] = self.period_start.to_i
      ret[:period_end] = self.period_end.to_i
      ret[:is_autorenewable] = self.is_autorenewable
      ret[:last_invoice_id] = self.last_invoice_id.to_s
      ret[:entries] = self.invoiceable_entries.collect{|e| e.to_api}
      ret[:invoiceable_amount] = self.invoiceable_amount
      ret[:state] = self.state
      return ret
    end

  end

end
