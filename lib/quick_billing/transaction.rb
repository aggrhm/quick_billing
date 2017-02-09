module QuickBilling

  module Transaction

    PRIMARY_TYPES = {charge: 1, payment: 2, credit: 3, refund: 4}
    STATES = {entered: 1, processing: 2, completed: 3, void: 4, error: 5}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_transaction!
        include QuickScript::Eventable
        include QuickScript::Model

        if self.respond_to?(:field)
          field :primary_type, type: Integer
          field :description, type: String
          field :amount, type: Integer
          field :state, type: Integer
          field :state_changed_at, type: Time
          field :status, type: String
          field :ref_id, type: String
          field :payment_method_data, type: Hash

          field :meta, type: Hash, default: Hash.new

          field :subscription_id, type: Integer
          field :account_id, type: Integer
          field :invoice_id, type: Integer
          field :coupon_id, type: Integer

          timestamps!
        end

        belongs_to :subscription, :class_name => QuickBilling.classes[:subscription]
        belongs_to :account, :class_name => QuickBilling.classes[:account]
        belongs_to :invoice, :class_name => QuickBilling.classes[:invoice]
        belongs_to :coupon, :class_name => QuickBilling.classes[:coupon]

        enum_methods! :primary_type, PRIMARY_TYPES
        enum_methods! :state, STATES

        scope :completed, lambda {
          where(state: STATES[:completed])
        }
        scope :for_account, lambda {|acct_id|
          where(account_id: acct_id)
        }
        scope :with_account_id, lambda {|acct_id|
          where(account_id: acct_id)
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
        scope :has_primary_type, lambda {|tp|
          where(primary_type: tp)
        }
        scope :before, lambda {|t|
          where("created_at < ?", t)
        }
        scope :on_or_after, lambda {|t|
          where("created_at >= ?", t)
        }

        attr_accessor :payment_method

        validate do
          errors.add(:primary_type, "Needs primary type.") if self.primary_type.blank?
          errors.add(:state, "Needs state.") if self.state.blank?
          errors.add(:ref_id, "Needs ref id.") if self.primary_type?(:payment) || self.primary_type?(:refund)
          errors.add(:amount, "Needs amount.") if self.amount.blank?
        end
        
      end

      def enter_charge!(acct, amt, opts={})
        t = self.new
        t.primary_type! :charge
        t.description = opts[:description] || "Charge"
        t.amount = amt
        t.state!(opts[:state] || :completed)
        t.account = acct
        t.subscription = opts[:subscription]
        t.invoice = opts[:invoice]
        success = t.save
        if success
          t.account.modify_balance! amt
          t.report_event('completed')
        end
        return {success: success, data: t}
      end

      def enter_payment!(opts)
        acct = opts[:account]
        pm = opts[:payment_method]
        return {success: false, error: "Payment method not found."} if pm.nil?
        amt = opts[:amount]
        return {success: false, error: "Cannot charge non-positive amount."} if amt < 0
        t = self.new
        t.primary_type! :payment
        t.description = opts[:description] || "Payment"
        t.amount = amt
        t.state! :entered
        t.account = acct
        t.payment_method = pm
        t.payment_method_data = pm.to_api
        success = t.process_payment!
        if success
          t.account.modify_balance! -t.amount
          t.report_event('completed')
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
        t.primary_type! :credit
        t.description = opts[:description] || "Credit"
        t.amount = amt
        t.subscription = opts[:subscription] if opts[:subscription]
        t.coupon = opts[:coupon] if opts[:coupon]
        t.state! :completed
        t.account = acct
        if t.save
          success = true
          acct.modify_balance! -amt
          t.report_event('completed')
        end

        return {success: success, data: t}
      end

      def enter_manual_refund!(acct, amt, opts={})
        success = false
        t = self.new
        t.primary_type! :refund
        t.description = opts[:description] || "Manual Refund"
        t.amount = amt
        t.state! :completed
        t.account = acct
        if t.save
          success = true
          acct.modify_balance! amt
          t.report_event('completed')
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

    def primary_type_str
      PRIMARY_TYPES.invert[self.primary_type].to_s
    end

    # ACTIONS

    def void!
      self.state! :void
      self.save
      self.report_event('voided')
      return true
    end

    def process_payment!
      rid = nil
      success = true
      error = nil
      res = QuickBilling.platform.send_payment(
        amount: self.amount,
        payment_method_token: self.payment_method.token
      )
      self.ref_id = res[:id]
      if !res[:success]
        error = res[:error]
        raise error
      end
      self.state! :completed
      self.save(validate: false)

      report_event('completed')

    rescue => ex
      success = false
      error ||= "An unexpected error occurred processing this payment."
      QuickBilling.platform.void_payment(self.ref_id) if self.ref_id.present?
      QuickScript.log_exception(ex)
      self.state! :error
      self.status = error
      self.save(validate: false)
      report_event('error', action: 'process_payment', message: ex.message, backtrace: ex.backtrace)

    ensure
      return success
    end

    # HANDLERS

    def handle_event_internally(ev, opts)
      case ev
      when 'completed'
        self.account.needs_balancing!
      when 'voided'
        self.account.needs_balancing!
      end
    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:primary_type] = self.primary_type
      ret[:description] = self.description
      ret[:amount] = self.amount
      ret[:state] = self.state
      ret[:status] = self.status
      ret[:created_at] = self.created_at.to_i
      ret[:invoice_id] = self.invoice_id.to_s if self.invoice_id.present?
      ret[:payment_method_data] = self.payment_method_data if self.payment_method_data.present?
      return ret
    end

  end

end

