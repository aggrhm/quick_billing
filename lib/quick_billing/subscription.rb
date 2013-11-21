module QuickBilling

  module Subscription

    STATES = {inactive: 1, active: 2, canceled: 3}

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
        plan_key = opts[:plan_key]

        # find plan with plan key
        plan = BillingPlan.with_key(plan_key).first

        raise "No plan with key" if plan.nil?

        # create subscription
        sub = Subscription.new
        sub.account = account
        sub.plan_key = plan.key
        sub.amount = plan.price
        sub.state! :inactive
        sub.save

        # enter charge
        sub.enter_charge!

        return sub
      end

      def process_expired_subscriptions(opts={})
        self.active.expired.each do |sub|
          QuickUtils.unit_of_work do
            Rails.logger.info "#{Time.now.to_s}: Entering charge for subscription #{sub}."
            sub.enter_charge!
          end
        end
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS

    def plan
      BillingPlan.with_key(self.plan_key)
    end

    # TRANSACTIONS

    def enter_charge!
      result = Transaction.enter_charge_for_subscription!(sub)
      if result[:success]
        t = result[:data]
        self.expires_at = Time.now + self.plan.period
        self.last_charged_at = Time.now
        self.last_charged_amount = t.amount
        self.state! :active
        self.save
        # update account balance
        Job.run_later :meta, self.account, :update_account_balance
        return true
      else
        return false
      end

    end

    def cancel!
      self.expires_at = Time.now
      self.state! :canceled
      self.save
      Job.run_later :meta, self.account, :update_account_balance
    end

    # API

    def to_api
      ret = {}
      ret[:id] = self.id.to_s
      ret[:plan_key] = self.plan_key
      ret[:expires_at] = self.expires_at.to_i
      ret[:state] = self.state
      return ret
    end

  end

end
