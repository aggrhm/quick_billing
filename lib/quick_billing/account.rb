module QuickBilling

  # billing_info = {
	#   lpa_at : <time of last payment attempt>
	#   customer_id : <id of customer on billing platform>
	#   customer_pms : <array of payment methods>
	#   platform : <platform enum of customer>
	#   balance_state : <paid, delinquent>
	#   balance : <balance of account after transactions>
	#   balance_overdue_at : <date balance is overdue, account is delinquent> 
  # }

  module Account

    BALANCE_STATES = {paid: 1, delinquent: 2}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_account!
        include QuickBilling::ModelBase
        include QuickScript::Model
        if self.respond_to?(:field)
          field :customer_id, type: String
          field :platform, type: String
          field :balance, type: Integer, default: 0
          field :balance_overdue_at, type: Time
          field :last_payment_attempted_at, type: Time
          field :meta, type: Hash, default: Hash.new
          timestamps!
        end

        has_many :payment_methods, foreign_key: :account_id, class_name: QuickBilling.classes[:payment_method]

        scope :with_debt, lambda {
          where("balance > 0")
        }
        scope :with_payable_debt, lambda {
          where("balance > 200")
        }
        scope :payment_attempt_ready, lambda {
          where("last_payment_attempted_at is null or last_payment_attempted_at < ?", 1.day.ago)
        }
        scope :with_overdue_balance, lambda {
          where("balance_overdue_at < ?", Time.now)
        }

        before_destroy :delete_customer!

      end


      def process_unbilled_accounts(opts={})
        bfn = opts[:break_if]
        self.with_payable_debt.payment_attempt_ready.each do |acct|
          break if bfn && bfn.call == true
          Rails.logger.info "#{Time.now.to_s} : Adding job for unbilled payable account."
          Job.run_later :billing, acct, :enter_payment!
        end
      end

    end

    ## INSTANCE METHODS
    
    # returns first active subscription
    def active_subscription(reload=false)
      self.active_subscriptions(reload).first
    end

    def active_subscriptions(reload=false)
      if @active_subscriptions.nil? || reload
        @active_subscriptions = QuickBilling.Subscription.for_account(self.id).active.to_a
      end
      @active_subscriptions
    end

    # ACCESSORS

    def balance_state
      if self.balance > 200 && self.is_balance_overdue?
        return BALANCE_STATES[:delinquent]
      else
        return BALANCE_STATES[:paid]
      end
    end

    def is_paid?
      return self.balance_state == BALANCE_STATES[:paid]
    end
    def is_delinquent?
      return self.balance_state == BALANCE_STATES[:delinquent]
    end
    def is_balance_overdue?
      return false if self.balance_overdue_at.nil?
      return self.balance_overdue_at < Time.now
    end

    def customer_info
      # override this method with a hash of customer info
      return {}
    end

    def has_valid_payment_method?
      self.payment_methods.length > 0
    end

    def credit_cards
      self.payment_methods.select{|pm| pm.type?(:credit_card) }
    end

    # ACTIONS

    def ensure_customer_id!
      return self.customer_id unless self.customer_id.blank?
      result = QuickBilling.platform.create_customer(self.customer_info.merge({id: self.id.to_s}))
      if result[:success]
        self.customer_id = result[:id]
        self.platform = QuickBilling.options[:platform]
        self.save
      else
        return false
      end
      return self.customer_id
    end

    def save_payment_method(opts)
      opts[:customer_id] = self.ensure_customer_id!
      result = QuickBilling.platform.save_payment_method(opts)
      self.update_payment_methods
      return result
    end

    def delete_payment_method(opts)
      result = QuickBilling.platform.delete_payment_method(token: opts[:token])
      self.update_payment_methods
      return result
    end

    def update_payment_methods
      result = QuickBilling.platform.list_payment_methods(self.ensure_customer_id!)
      if result[:success]
        self.payment_methods = result[:data]
        self.save
      end
    end

    def update_balance
      # iterate all transactions
      old_bal = self.balance

      new_bal = 0
      QuickBilling.Transaction.completed.for_account(self.id).each do |tr|
        if tr.type?(:charge) || tr.type?(:refund)
          new_bal += tr.amount
        elsif tr.type?(:payment) || tr.type?(:credit)
          new_bal -= tr.amount
        end
      end


      if !self.balance_overdue_at.nil? && new_bal <= 0
        # if balance is now back to no debt, reset balance_overdue_at
        self.balance_overdue_at = nil
      elsif self.balance_overdue_at.nil? && new_bal > 0
        # if new balance is positive, set balance_overdue_at
        self.balance_overdue_at = Time.now + 3.days
      end

      self.balance = new_bal

      self.save
      return self.balance
    end

    def modify_balance!(amt)
      mv = Mongoid::VERSION.to_i
      if mv < 4
        self.inc(:bl, amt)
      else
        self.inc(bl: amt)
      end
    end

    def enter_payment!(amt = nil)
      self.last_payment_attempted_at = Time.now
      self.save

      amt ||= self.update_balance   # ensure balance up to date

      return {success: false, error: 'Payment amount must be greater than $2.'} if amt <= 200

      # check if customer has payment method
      return {success: false, error: "Account must have valid payment method."} if !self.has_valid_payment_method?

      result = QuickBilling.Payment.send_payment!({account: self, payment_method: self.payment_methods[0], amount: amt})
      return result
    end

    def redeem_coupon!(coupon)
      if !coupon.transactionable? || !coupon.redeemable_by_account?(self.id)
        return {success: false, error: "This coupon is not valid."}
      end
      result = QuickBilling.Transaction.enter_redeemed_coupon!(self, coupon)
      if result[:success]
        return {success: true, data: coupon, transaction: result[:data]}
      else
        return {success: false, data: coupon, error: result[:error]}
      end
    end

    def update_platform_info
      return if self.customer_id.nil?
      cust = QuickBilling.platform.find_customer(self.customer_id)
      if cust.nil?
        self.customer_id = nil
      end
      self.update_payment_methods
    end

    def ensure_payment_transactions
      QuickBilling.Payment.for_account(self.id).each do |payment|
        if QuickBilling.Transaction.for_payment(payment.id).count == 0
          QuickBilling.Transaction.enter_completed_payment!(payment)
        end
      end
    end

    def delete_customer!
      if customer_id.present?
        res = QuickBilling.platform.delete_customer(customer_id: customer_id)
        return res[:success]
      else
        return true
      end
    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:balance] = self.balance
      ret[:balance_state] = self.balance_state
      ret[:balance_overdue_at] = self.balance_overdue_at.to_i unless self.balance_overdue_at.nil?
      #ret[:payment_methods] = self.payment_methods.collect(&:to_api)
      #ret[:active_subscription_ids] = self.active_subscriptions.collect{|s| s.id.to_s}
      return ret
    end

  end

end
