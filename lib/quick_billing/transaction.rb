module QuickBilling

  module Transaction
    include QuickBilling::ModelBase

    TYPES = {charge: 1, payment: 2, credit: 3, refund: 4}
    STATES = {entered: 1, processing: 2, completed: 3, void: 4, error: 5}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_transaction!
        include QuickBilling::ModelBase
        include QuickScript::Model

        if self.respond_to?(:field)
          field :type, type: Integer
          field :description, type: String
          field :amount, type: Integer
          field :state, type: Integer
          field :state_changed_at, type: Time
          field :status, type: String
          field :meta, type: Hash, default: Hash.new

          field :subscription_id, type: Integer
          field :account_id, type: Integer
          field :payment_id, type: Integer
          field :invoice_id, type: Integer
          field :coupon_id, type: Integer

          timestamps!
        end

        belongs_to :subscription, :class_name => QuickBilling.classes[:subscription]
        belongs_to :account, :class_name => QuickBilling.classes[:account]
        belongs_to :payment, :class_name => QuickBilling.classes[:payment]
        belongs_to :invoice, :class_name => QuickBilling.classes[:invoice]
        belongs_to :coupon, :class_name => QuickBilling.classes[:coupon]

        enum_methods! :type, TYPES
        enum_methods! :state, STATES

        scope :completed, lambda {
          where(state: STATES[:completed])
        }
        scope :for_account, lambda {|acct_id|
          where(account_id: acct_id).desc(:created_at)
        }
        scope :for_invoice, lambda {|inv_id|
          where(invoice_id: inv_id)
        }
        scope :for_payment, lambda {|pid|
          where(payment_id: pid)
        }
        scope :for_coupon, lambda {|cid|
          where(coupon_id: cid)
        }
        scope :has_type, lambda {|tp|
          where(type: tp)
        }
        scope :before, lambda {|t|
          where("created_at < ?", t)
        }
        scope :on_or_after, lambda {|t|
          where("created_at >= ?", t)
        }
        
      end

      def enter_charge!(acct, amt, opts)
        t = self.new
        t.type! :charge
        t.description = opts[:description]
        t.amount = amt
        t.state!(opts[:state] || :completed)
        t.account = acct
        t.subscription = opts[:subscription]
        t.invoice = opts[:invoice]
        success = t.save
        if success
          t.account.modify_balance! amt
          self.report_event('completed')
        end
        return {success: success, data: t}
      end

      def enter_completed_payment!(payment, opts={})
        if !self.for_payment(payment.id).first.nil?
          return {success: false, error: "Transaction already completed for payment"}
        end

        success = false
        t = self.new
        t.type! :payment
        t.description = "Payment"
        t.payment = payment
        t.amount = payment.amount
        t.state! :completed
        t.account = payment.account
        success = t.save
        if success
          t.account.modify_balance! -t.amount
          self.report_event('completed')
        end

        return {success: success, data: t}
      end

      def enter_redeemed_coupon!(acct, coupon, opts={})
        if !coupon.transactionable?
          return {success: false, error: "This coupon cannot be entered as a transaction."}
        end
        desc = "Coupon: #{coupon.title}"
        result = self.enter_credit!(acct, coupon.amount, {description: desc, coupon: coupon})
        return result
      end

      def enter_credit!(acct, amt, opts={})
        success = false
        t = self.new
        t.type! :credit
        t.description = opts[:description] || "Credit"
        t.amount = amt
        t.subscription = opts[:subscription] if opts[:subscription]
        t.coupon = opts[:coupon] if opts[:coupon]
        t.state! :completed
        t.account = acct
        if t.save
          success = true
          acct.modify_balance! -amt
          self.report_event('completed')
        end

        return {success: success, data: t}
      end

      def enter_manual_refund!(acct, amt, opts={})
        success = false
        t = self.new
        t.type! :refund
        t.description = opts[:description] || "Manual Refund"
        t.amount = amt
        t.state! :completed
        t.account = acct
        if t.save
          success = true
          acct.modify_balance! amt
          self.report_event('completed')
        end

        return {success: success, data: t}
      end

      def void!(tr_id)
        t = self.find(tr_id)
        return {success: false, error: 'Transaction not found'} if t.nil?
        t.void!
        return {success: true, data: t}
      end

    end

    ## INSTANCE METHODS

    # ACCESSORS

    def type_str
      TYPES.invert[self.type].to_s
    end

    # ACTIONS

    def void!
      self.state! :void
      self.save
      self.report_event('voided')
      return true
    end

    # HANDLERS

    def handle_event_locally(ev, opts)
      case ev
      when 'completed'
        Job.run_later :meta, self.account, :update_balance
      when 'voided'
        Job.run_later :meta, self.account, :update_balance
      end
    end

    def to_api(opt=:full)
      ret = {}

      ret[:id] = self.id.to_s
      ret[:type] = self.type
      ret[:description] = self.description
      ret[:amount] = self.amount
      ret[:state] = self.state
      ret[:created_at] = self.created_at.to_i
      ret[:invoice_id] = self.iid.to_s

      return ret
    end

  end

end

