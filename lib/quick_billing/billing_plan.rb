module QuickBilling

  module BillingPlan

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_billing_plan_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :nm, as: :name, type: String
          field :ky, as: :key, type: String
          field :pr, as: :price, type: Integer
          field :pi, as: :period_interval, type: Integer, default: 1   # period in months
          field :pu, as: :period_unit, type: String, default: 'month'   # period in months

          mongoid_timestamps!

        end
      end

      def add_plan!(key, name, price)
        plan = self.new
        plan.key = key.to_s
        plan.name = name
        plan.price = price
        plan.save
        return plan
      end

      def with_key(key)
        self.where(ky: key).first
      end

    end

    ## INSTANCE METHODS

    def period
      return self.period_interval.months
    end

    def to_api(opt)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:name] = self.name
      ret[:key] = self.key
      ret[:price] = self.price

      return ret
    end

  end

end
