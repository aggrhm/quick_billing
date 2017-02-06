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
        include QuickJobs::Processable

        if self.respond_to?(:field)
          field :customer_id, type: String
          field :platform, type: String
          field :balance, type: Integer, default: 0
          field :balance_overdue_at, type: Time
          field :last_payment_attempted_at, type: Time
          field :needs_balancing, type: :boolean, default: false

          field :meta, type: Hash, default: Hash.new

          field :default_payment_method_id, type: Integer
          timestamps!
        end

        processable!

        has_many :payment_methods, foreign_key: :account_id, class_name: QuickBilling.classes[:payment_method]

        scope :with_debt, lambda {
          where("balance > 0")
        }
        scope :with_payable_debt, lambda {
          where(needs_balancing: false).where("balance > 200")
        }
        scope :payment_attempt_ready, lambda {
          where("last_payment_attempted_at is null or last_payment_attempted_at < ?", 1.day.ago)
        }
        scope :with_overdue_balance, lambda {
          where("balance_overdue_at < ?", Time.now)
        }
        scope :needs_balancing, lambda {
          where(needs_balancing: true)
        }

        before_destroy :delete_customer!

      end

      def process_unbilled_accounts(opts={})
        bfn = opts[:break_if]
        self.process_each!(with_payable_debt.payment_attempt_ready, id: 'process_unbilled_accounts') do |acct|
          break if bfn && bfn.call == true
          Rails.logger.info "Processing unbilled payable account."
          acct.enter_payment!
        end
      end

      def process_unbalanced_accounts(opts={})
        self.process_each!(needs_balancing, id: 'process_unbalanced_accounts') do |acct|
          acct.update_balance
        end
      end

    end

    ## INSTANCE METHODS

    def update_as_action!(opts)
      new_record = self.new_record?

      report_event 'updating', raise_exceptions: true

      success = self.save
      error = self.error_message
      if success
        if new_record
          if self.ensure_customer_id! == false
            raise "Could not setup customer id"
          end
        end
        report_event 'updated'
      end
    rescue => ex
      success = false
      error = ex.message
      self.destroy if new_record && persisted?
    ensure
      return {success: success, data: self, error: error, new_record: new_record}
    end
    
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
      self.payment_methods.select{|pm| pm.payment_type?(:credit_card) }
    end

    def default_payment_method
      if self.default_payment_method_id.present?
        pm = QuickBilling.PaymentMethod.find(self.default_payment_method_id)
      end
      if pm.nil?
        pm = self.payment_methods.last
      end
      return pm
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

    def update_balance
      # iterate all transactions
      old_bal = self.balance

      new_bal = 0
      QuickBilling.Transaction.completed.for_account(self.id).each do |tr|
        if tr.primary_type?(:charge) || tr.primary_type?(:refund)
          new_bal += tr.amount
        elsif tr.primary_type?(:payment) || tr.primary_type?(:credit)
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
      self.needs_balancing = false

      self.save
      return self.balance
    end

    def needs_balancing!
      self.update_attribute :needs_balancing, true
    end

    def modify_balance!(amt)
      nb = self.balance + amt
      self.update_attribute :balance, nb
    end

    def enter_payment!(amt = nil)
      self.last_payment_attempted_at = Time.now
      self.save

      amt ||= self.update_balance   # ensure balance up to date

      return {success: false, error: 'Payment amount must be greater than $2.'} if amt <= 200

      # check if customer has payment method
      return {success: false, error: "Account must have valid payment method."} if !self.has_valid_payment_method?

      result = QuickBilling.Transaction.enter_payment!(account: self, payment_method: self.default_payment_method, amount: amt)
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
      ret[:default_payment_method_id] = self.default_payment_method_id ? self.default_payment_method_id.to_s : nil
      #ret[:payment_methods] = self.payment_methods.collect(&:to_api)
      #ret[:active_subscription_ids] = self.active_subscriptions.collect{|s| s.id.to_s}
      return ret
    end

  end

end
