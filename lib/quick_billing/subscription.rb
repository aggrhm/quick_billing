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
          field :am, as: :amount, type: Integer
          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :ex_at, as: :expires_at, type: Time
          field :lc_at, as: :last_charged_at, type: Time
          field :lc, as: :last_charged_amount, type: Integer

          belongs_to :account, :foreign_key => :aid, :class_name => 'BillingAccount'

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

      def subscribe_to_plan(account, plan_key)
        # find plan with plan key
        plan = QuickBilling.models[:billing_plan].with_key(plan_key)

        return {success: false, error: "No plan with key"} if plan.nil?

        # create subscription
        sub = self.new
        sub.account = account
        sub.plan_key = plan.key
        sub.amount = plan.price
        sub.state! :inactive
        sub.save

        # enter charge
        result = sub.enter_charge!
        return {success: false, data: sub, error: 'Could not activate subscription.'} if result[:success] == false

        Job.run_later :billing, sub, :handle_activated
        return {success: true, data: sub}
      end

      def process_expired_subscriptions(opts={})
        self.active.expired.each do |sub|
          Rails.logger.info "#{Time.now.to_s} : Adding job for expired subscription."
          Job.run_later :billing, sub, :enter_charge!
        end
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS

    def plan
      QuickBilling.models[:billing_plan].with_key(self.plan_key)
    end

    # TRANSACTIONS

    def enter_charge!
      result = QuickBilling.models[:transaction].enter_charge_for_subscription!(self)
      if result[:success]
        per_start = self.expires_at || Time.now
        t = result[:data]
        self.expires_at = per_start + self.plan.period
        self.last_charged_at = Time.now
        self.last_charged_amount = t.amount
        self.state! :active
        self.save
        # update account balance
        Job.run_later :billing, self, :handle_charged
        return {success: true}
      else
        return {success: false}
      end
    end

    def cancel!
      exp = self.expires_at

      # issue credit
      if self.state?(:active) && exp > Time.now && self.last_charged_amount > 0
        time_rem = exp - Time.now
        time_rem_f = time_rem / self.plan.period
        credit_due = (time_rem_f * self.last_charged_amount).to_i
        result = QuickBilling.models[:transaction].enter_credit!(self.account, credit_due, {description: 'Subscription cancellation credit'})
        return {success: false, error: 'Could not issue credit for cancellation.'} if result[:success] == false
      end

      # cancel subscription
      self.expires_at = Time.now
      self.state! :cancelled
      self.save

      # update balance
      Job.run_later :billing, self, :handle_cancelled
      return {success: true}
    end

    def handle_activated

    end

    def handle_charged
    end

    def handle_cancelled
    end

    # API

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:plan_key] = self.plan_key
      ret[:plan] = self.plan.to_api
      ret[:expires_at] = self.expires_at.to_i
      ret[:state] = self.state
      return ret
    end

  end

end
