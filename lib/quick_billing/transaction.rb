module QuickBilling

  module Transaction

    TYPES = {charge: 1, payment: 2, credit: 3, refund: 4}
    STATES = {entered: 1, processing: 2, completed: 3, void: 4}

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
          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :mth, as: :meta, type: Hash, default: Hash.new
          field :er, as: :error_message, type: String

          belongs_to :subscription, :foreign_key => :sid, :class_name => 'Subscription'
          belongs_to :account, :foreign_key => :aid, :class_name => 'BillingAccount'

          enum_methods! :type, TYPES
          enum_methods! :state, STATES

          mongoid_timestamps!

          scope :for_account, lambda {|acct_id|
            where(aid: acct_id)
          }

          scope :completed, lambda {
            where(st: STATES[:completed])
          }
        end
      end

      def enter_charge_for_subscription!(sub)
        t = self.new
        t.type! :charge
        t.description = sub.plan.name
        t.amount = sub.amount
        t.state! :completed
        t.account = sub.account
        t.subscription = sub
        if t.save
          return {success: true, data: t}
        else
          return {success: false, data: t}
        end
      end

      def enter_payment!(acct, amt, opts={})
        success = false
        t = self.new
        t.type! :payment
        t.description = "Payment"
        t.amount = amt
        t.state! :entered
        t.account = acct
        if t.save
          if t.process_payment!
            success = true
          end
        end

        return {success: success, data: t}
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS


    # ACTIONS

    def process_payment!
      acct = t.account
      result = QuickBilling.platform.send_payment(
        amount: t.amount,
        customer_id: acct.billing_info['customer_id']
      )

      t.meta['platform'] = QuickBilling.options[:platform]
      if result[:success]
        t.state! :completed
        t.meta['transaction_id'] = result[:id]
        t.save
        return true
      else
        t.state! :void
        t.meta['transaction_id'] = result[:id]
        t.error_message = result[:error]
        t.save
        return false
      end
    end

    def to_api(opt)
      ret = {}

      ret[:id] = self.id.to_s
      ret[:type] = self.type
      ret[:description] = self.description
      ret[:amount] = self.amount
      ret[:state] = self.state
      ret[:created_at] = self.created_at.to_i

      return ret
    end

  end

end

