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
          field :ar, as: :is_autorenewable, type: Boolean, default: false
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

      # NOTE: this function should build a subscription but not save it, so that you
      # can build and test changes to a subscription without committing the entries to
      # the database.
      def build_for_account(account, base_entries, opts={})
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
          res = sub.add_entry(entry)
          if res[:success] == false
            return {success: false, data: sub, error: res[:error]}
          end
        end

        inv = sub.build_invoice
        return {success: false, error: "Could not build invoice"} if inv.nil?
        if opts[:start] != true && opts[:start] != "true"
          return {success: true, data: sub}
        end

        # ensure credit card if amount is positive
        if inv.total > 0 && !sub.account.has_valid_payment_method?
          return {success: false, data: sub, error: "Billing account for this subscription must have a valid payment method"}
        end

        # commit everything
        sub.save_with_entries

        # enter charge
        result = sub.renew!
        return {success: false, data: sub, error: result[:error]} if result[:success] == false

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

    def product_entries(reload=false)
      self.invoiceable_entries(reload).select{|e| e.source? :product }
    end

    def last_invoice
      @last_invoice ||= QuickBilling.Invoice.find(self.last_invoice_id)
    end

    def invoiceable_entries(reload=false)
      if !self.new_record? && (@invoiceable_entries.nil? || reload)
        @invoiceable_entries = QuickBilling.Entry.for_subscription(self.id).invoiceable.to_a
      end
      @invoiceable_entries ||= []
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

    def last_charged_transaction
      li = self.last_invoice
      return nil if li.nil?
      tr = li.charged_transaction
      return nil if tr.nil?
      return tr
    end

    def prorateable_amount
      # check if time left in subscription
      if !self.state?(:active) || self.expired?
        return 0
      end
      # check if anything charged
      tr = self.last_charged_transaction
      if tr.nil? || (tr.amount <= 0)
        return 0
      end

      exp = self.period_end
      amt = tr.amount
      time_rem = exp - Time.now
      time_rem_f = time_rem / (exp - self.period_start)
      credit_due = (time_rem_f * amt).to_i
      return [credit_due, amt].min
    end

    # TRANSACTIONS

    # Adds entry to this subscription. Only saves if subscription is already saved.
    
    def save_with_entries
      if !self.valid?
        return {success: false, data: self, error: self.errors.values.flatten[0]}
      end

      self.save
      self.invoiceable_entries.each do |entry|
        entry.subscription = self if entry.sid.nil?
        entry.account = self.account if entry.aid.nil?
        entry.save
      end
      return {success: true, data: self}
    end

    def add_entry(opts)
      opts = opts.symbolize_keys
      entries = self.invoiceable_entries(true)

      # build entry
      case opts[:source]
      when QuickBilling::Entry::SOURCES[:product]
        product = QuickBilling.Product.find(opts[:ref_id])
        if product.nil? || !product.is_available? || product.period_length_hash != self.period_length_hash
          return {success: false, error: "Product not available"}
        end
        e = QuickBilling.Entry.build_from_product(product, opts[:quantity].to_i)

      when QuickBilling::Entry::SOURCES[:discount]
        coupon = QuickBilling.Coupon.find_with_code(opts[:ref_id])
        if coupon.nil? || !coupon.redeemable_by_account?(account.id) || !coupon.style?(:subscription)
          return {success: false, error: "Coupon code is invalid"}
        end
        if entries.any?{|en| en.coupon_id == coupon.id}
          return {success: false, error: "Coupon already added"}
        end
        e = QuickBilling.Entry.build_from_coupon(coupon)
      else
        return {success: false, error: "Unrecognized subscribed entry"}
      end

      if !e.valid?
        return {success: false, data: e, error: "Subscription entry invalid"}
      end

      if self.new_record?
        entries << e
      else
        e.subscription = self
        e.account = self.account
        if !e.save
          return {success: false, error: "Could not save subscription entry"}
        end
      end
      return {success: true, data: e}
    end

    # Removes entry if not saved, deletes entry if not invoiced.
    # Otherwise prevents entry from being invoiced anymore.
    #
    def remove_entry(entry)
      if entry.new_record?
        entries = self.invoiceable_entries(true)
        entries.delete(entry)
      else
        if !entry.invoiced?
          entry.destroy
        else
          entry.state! :voided
          entry.save
        end
      end
      return {success: true}
    end

    def finalize_entries!
      # override this method to make changes to entries (i.e. adjust quantities)
      return true
    end

    def build_invoice
      return nil if !self.finalize_entries!
      entries = self.invoiceable_entries(true)
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

    def renew!(opts={})
      is_activating = !self.state?(:active)
      if self.state?(:active) && !self.expired?
        return {success: false, error: "Cannot renew this subscripton because it has more time left."}
      end

      inv = self.build_invoice
      return {success: false, error: "Could not build invoice"} if inv.nil?

      begin
        resp = inv.charge_to_account!(self.account)
        if resp[:success]
          if self.state?(:active)
            # already active, just advance from previous period
            self.period_start = self.period_end
          else
            self.period_start = Time.now
          end
          self.period_end = self.period_start + self.period_length
          self.last_invoice_id = inv.id
          self.state! :active
          self.save
          Job.run_later :billing, self, :handle_renewed
          Job.run_later(:billing, self, :handle_activated) if is_activating
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

    def cancel_at_end!
      return {success: false, error: "Subscription is not active"} if !self.state?(:active)
      self.is_autorenewable = false
      self.save
      Job.run_later :billing, self, :handle_cancelled
      return {success: true}
    end

    def cancel!
      return {success: false, error: "Subscription is not active"} if !self.state?(:active)
      exp = self.period_end
      tr = self.last_charged_transaction

      if self.is_prorateable && (credit_due = self.prorateable_amount) > 0
        result = QuickBilling.Transaction.enter_credit!(self.account, credit_due, {description: 'Subscription cancellation credit', subscription: self})
        return {success: false, error: 'Could not issue credit for cancellation.'} if result[:success] == false
      end

      # cancel subscription
      self.period_end = Time.now if !self.expired?
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
