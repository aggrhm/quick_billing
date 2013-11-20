module QuickBilling

  module Accountable

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_accountable_keys_for(db)
        if db == :mongoid
          field :bih, as: :billing_info, type: Hash, default: Hash.new
        end
      end

    end

    ## INSTANCE METHODS

    def ensure_customer_id!
      return unless self.billing_info['customer_id'].nil?
      result = QuickBilling.platform.create_customer({id: self.id, first_name: self.first_name, last_name: self.last_name, email: self.email})
      if result[:success]
        self.billing_info['customer_id'] = result[:data]
        self.billing_info['platform'] = QuickBilling.options[:platform]
        self.save
      else
        raise "Could not create customer!"
      end
    end

    def save_credit_card(opts)
      self.ensure_customer_id!
      result = QuickBilling.platform.save_credit_card(
        token: opts[:token],
        customer_id: self.billing_info['customer_id'],
        number: opts[:number].to_s,
        expiration_date: opts[:expiration_date]
      )
      if result[:success]
        self.update_customer_accounts
        return result  # return payment method
      else
        return result
      end

    end

    def update_customer_accounts
      self.ensure_customer_id!
      result = QuickBilling.platform.list_customer_accounts(self.billing_info['customer_id'])
      if result[:success]
        self.billing_info['customer_pms'] = result[:data].collect(&:to_api)
        self.save
      end
    end

    def subscribe_to_single_plan(opts)
      plan_key = opts[:plan_key]
      self.subscription.cancel if self.subscription
      sub = Subscription.subscribe_to_plan(user, plan_key)
      self.subscription = sub
      self.save
    end

  end

end
