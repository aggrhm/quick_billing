module QuickBilling

  module Subscription

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def subscribe_to_plan(accountable, plan_key)
        plan_key = opts[:plan_key]

        # find plan with plan key
        plan = BillingPlan.with_key(plan_key).first

        raise "No plan with key" if plan.nil?

        # create subscription
        sub = Subscription.new
        sub.accountable = accountable
        sub.plan_key = plan.key
        sub.state! :inactive
        sub.save

        # enter charge
        sub.enter_charge!

        return sub
      end


    end

    ## INSTANCE METHODS

    def enter_charge!
      result = Transaction.enter_charge_for_subscription!(sub)
      if result[:success]
        t = result[:data]
        self.expires_at = Time.now + self.plan.period
        self.last_charged_at = Time.now
        self.last_charged_amount = t.amount
        self.state! :active
        self.save
        return true
      else
        return false
      end

    end

    def cancel!

    end

  end

end
