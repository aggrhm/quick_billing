module QuickBilling

  module Transaction
    include QuickBilling::ModelBase

    TYPES = {charge: 1, payment: 2, credit: 3, refund: 4}
    STATES = {entered: 1, processing: 2, completed: 3, void: 4, error: 5}

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
          field :sa, as: :status, type: String

          belongs_to :subscription, :foreign_key => :sid, :class_name => QuickBilling.classes[:subscription]
          belongs_to :account, :foreign_key => :aid, :class_name => QuickBilling.classes[:account]
          belongs_to :payment, :foreign_key => :pid, :class_name => QuickBilling.classes[:payment]
          belongs_to :invoice, :foreign_key => :iid, :class_name => QuickBilling.classes[:invoice]
          belongs_to :coupon, :foreign_key => :cid, :class_name => QuickBilling.classes[:coupon]

          enum_methods! :type, TYPES
          enum_methods! :state, STATES

          mongoid_timestamps!

          scope :completed, lambda {
            where(st: STATES[:completed])
          }
          scope :for_account, lambda {|acct_id|
            where(aid: acct_id).desc(:created_at)
          }
          scope :for_invoice, lambda {|inv_id|
            where(iid: inv_id)
          }
          scope :for_payment, lambda {|pid|
            where(pid: pid)
          }
          scope :for_coupon, lambda {|cid|
            where(cid: cid)
          }
          scope :type_is, lambda {|tp|
            where('tp' => {'$in' => tp})
          }
          scope :before, lambda {|t|
            where('c_at' => {'$lt' => t})
          }
          scope :on_or_after, lambda {|t|
            where('c_at' => {'$gte' => t})
          }
          
        end
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

    def handle_event(ev, opts)
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

