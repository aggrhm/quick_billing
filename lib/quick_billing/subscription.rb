module QuickBilling

  module Subscription

    STATES = {inactive: 1, active: 2, cancelled: 3}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_subscription_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :pk, as: :plan_key, type: String
          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :p_st, as: :period_start, type: Time
          field :p_end, as: :period_end, type: Time
          field :li_id, as: :last_invoice_id
          field :qn, as: :quantity, type: Integer, default: 1
          field :ar, as: :autorenew, type: Boolean, default: true

          belongs_to :account, :foreign_key => :aid, :class_name => QuickBilling.Account.to_s
          has_many :adjustments, :class_name => QuickBilling.Adjustment.to_s, :dependent => :destroy

          mongoid_timestamps!

          enum_methods! :state, STATES

          scope :active, lambda {
            where(st: STATES[:active])
          }
          scope :expired, lambda {
            where(:ex_at => {'$lt' => Time.now})
          }
          scope :for_account, lambda {|aid|
            where(aid: aid)
          }
        end

      end

      def subscribe_to_plan(account, plan_key, opts={})
        # find plan with plan key
        plan = QuickBilling.Plan.find_with_key(plan_key)

        return {success: false, error: "No plan with key"} if plan.nil?
        return {success: false, error: "Plan is no longer available"} if !plan.is_available?

        # create subscription
        sub = self.new
        sub.account = account
        sub.plan_key = plan.key
        sub.state! :inactive
        sub.autorenew = true
        sub.quantity = opts[:quantity].to_i if opts[:quantity]
        
        # handle coupons
        if opts[:coupon_codes]
          coupon_codes = opts[:coupon_codes].split(",") if opts[:coupon_codes].is_a?(String)
          coupon_codes.each do |code|
            coupon = QuickBilling.Coupon.find_with_code(code)
            if coupon.nil? || !coupon.redeemable_by_account?(account.id)
              return {success: false, error: "Coupon code is invalid"}
            else
              res = sub.add_adjustment({coupon: coupon}) if coupon
              if res[:success] = false
                return {success: false, data: sub, error: res[:error]}
              end
            end
          end
        end

        if opts[:start] != true && opts[:start] != "true"
          return {success: true, data: sub}
        end

        # ensure credit card if amount is positive
        if sub.final_amount > 0 && !sub.account.has_valid_payment_method?
          return {success: false, data: sub, error: "Billing account for this subscription must have a valid payment method"}
        end

        sub.save

        # enter charge
        result = sub.renew!
        return {success: false, data: sub, error: 'Could not activate subscription.'} if result[:success] == false

        Job.run_later :billing, sub, :handle_activated
        return {success: true, data: sub}
      end

      def process_expired_subscriptions(opts={})
        self.active.expired.each do |sub|
          Rails.logger.info "#{Time.now.to_s} : Adding job for expired subscription."
          if sub.autorenew == true
            Job.run_later :billing, sub, :renew!
          else
            Job.run_later :billing, sub, :cancel!
          end
        end
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS

    def plan
      QuickBilling.Plan.find_with_key(self.plan_key)
    end

    def last_invoice
      QuickBilling.Invoice.find(self.last_invoice_id)
    end

    def discounts
      Adjustment.for_subscription(self.id).from_discount
    end

    def taxes
      Adjustment.for_subscription(self.id).from_tax
    end

    def expired?
      self.period_end < Time.now
    end

    def add_adjustment(opts)

      adj = QuickBilling.Adjustment.new
      if (coupon = opts[:coupon])
        adj.name = "Coupon"
        adj.source! :discount
        adj.amount = coupon.amount
        adj.percent = coupon.percent
        adj.times_used = 0
        adj.max_uses = coupon.max_uses
        adj.coupon_code = coupon.code
        adj.subscription = self
        adj.account = self.account
        if self.adjustments.select{|adj| adj.coupon_code == coupon.code}.length > 0
          return {success: false, error: "Coupon code already added"}
        end
        if !coupon.style?(:subscription)
          return {success: false, error: "Coupon is not for subscriptions"}
        end
      end
      if adj.save
        return {success: true, data: adj}
      else
        return {success: false, error: adj.error_message}
      end
    end

    def amount
      self.quantity * self.plan.price
    end

    def upcoming_invoice
      inv = Invoice.new
      inv.subscription = self
      inv.account = self.account
      inv.state! :open
      # add plan
      inv.add_item("#{self.plan.name} Plan (Quantity: #{self.quantity})", self.amount)
      # add adjustments
      # process discount adjustments first
      adjs = self.usable_adjustments
      adjs.select{|adj| adj.source?(:discount)}.each do |adj|
        inv.add_adjustment("Discount", #{
        a = adj.adjust_amount(a)
      end
      # then process tax adjustments
      adjs.select{|adj| adj.source?(:tax)}.each do |adj|
        a = adj.adjust_amount(a)
      end

      a = 0 if a < 0 
      return a
    end

    def final_amount
      self.adjusted_amount
    end

    # TRANSACTIONS

    def renew!
      if !self.expired?
        return {success: false, error: "Cannot renew this subscripton because it has more time left."}
      end

      amt = self.final_amount
      success = false
      t = nil
      if amt > 0
        res = QuickBilling.enter_charge!(self.account, self.final_amount, {
          description: "Subscription: #{self.plan.name}",
          subscription: self
        })
        success = res[:success]
        t = res[:data]
      else
        success = true
      end

      if result[:success]
        self.period_start = self.period_end || Time.now
        self.period_end = self.period_start + self.plan.period
        self.last_invoice_id = 
        self.state! :active
        self.save
        # update account balance
        Job.run_later :billing, self, :handle_renewed
        return {success: true}
      else
        return {success: false}
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

    def handle_activated
    end
    def handle_renewed
      # increment adjustments
      self.usable_adjustments.each do |adj|
        adj.times_used += 1 if !adj.max_uses.nil?
      end
      self.save
    end
    def handle_cancelled
    end

    # API

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:plan_key] = self.plan_key
      ret[:plan] = self.plan.to_api
      ret[:amount] = self.amount
      ret[:final_amount] = self.final_amount
      ret[:quanity] = self.quantity
      ret[:period_start] = self.period_start.to_i
      ret[:period_end] = self.period_end.to_i
      ret[:last_invoice_id] = self.last_invoice_id.to_s
      ret[:state] = self.state
      return ret
    end

  end

end
