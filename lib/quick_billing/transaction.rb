module QuickBilling

  module Transaction

    TYPES = {charge: 1, payment: 2, credit: 3, refund: 4}
    STATES = {processing: 1, cleared: 2, void: 3}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_transaction_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :tp, as: :type, type: Integer
          field :ds, as: :description, type: String
          field :am, as: :amount, type: Integer
          field :pk, as: :plan_key, type: String
          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :mth, as: :meta, type: Hash, default: Hash.new
          field :aid, as: :accountable_id, type: Moped::BSON::ObjectId
          field :acl, as: :accountable_class, type: String

          enum_methods! :type, TYPES
          enum_methods! :state, STATES

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

      def enter_charge_for_plan!(opts)

      end

      def enter_payment!(opts)

      end

    end

    ## INSTANCE METHODS

    def accountable
      return nil if self.accountable_class.nil? || self.accountable_id.nil?
      base = Object.const_get(self.accountable_class)
      return base.find(self.accountable_id)
    end

    def accountable=(val)
      self.accountable_class = val.class.to_s
      self.accountable_id = val.id
      return val
    end

    def to_api(opt)
      ret = {}

      ret[:id] = self.id.to_s
      ret[:type] = self.type
      ret[:description] = self.description
      ret[:amount] = self.amount
      ret[:state] = self.state

      return ret
    end

  end

end

