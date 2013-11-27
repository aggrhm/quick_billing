module QuickBilling

  # billing_info = {
	#   lpa_at : <time of last payment attempt>
	#   customer_id : <id of customer on billing platform>
	#   customer_pms : <array of payment methods>
	#   platform : <platform enum of customer>
	#   state : <paid, delinquent>
	#   balance : <balance of account after transactions>
	#   balance_overdue_at : <date balance is overdue, account is delinquent> 
  # }

  module BillingAccount

    STATES = {paid: 1, delinquent: 2}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_account_keys_for(db)
        if db == :mongoid
          field :cid, as: :customer_id, type: String
          field :pms, as: :payment_methods, type: Array, default: []
          field :pf, as: :platform, type: String
          field :bl, as: :balance, type: Integer, default: 0
          field :bo_at, as: :balance_overdue_at, type: Time
          field :pa_at, as: :last_payment_attempted_at, type: Time
          field :mth, as: :meta, type: Hash, default: Hash.new

          belongs_to :user, :foreign_key => :uid, :class_name => 'User'

          scope :with_debt, lambda {
            where('bl' => {'$gt' => 0})
          }
          scope :with_payable_debt, lambda {
            where('bl' => {'$gt' => 200})
          }

          scope :payment_attempt_ready, lambda {
            where('$or' => [{'pa_at' => {'$lt' => 1.day.ago}}, {'pa_at' => nil}])
          }

          scope :with_overdue_balance, lambda {
            where('bo_at' => {'$lt' => Time.now})
          }

          scope :owned_by, lambda {|uid|
            where(uid: uid)
          }
        end
      end

      def process_unbilled_accounts
        self.with_payable_debt.payment_attempt_ready.each do |acct|
          Rails.logger.info "#{Time.now.to_s} : Adding job for unbilled payable account."
          Job.run_later :billing, acct, :enter_payment!
        end
      end

    end

    ## INSTANCE METHODS
    
    # returns first active subscription
    def active_subscription
      self.active_subscriptions.first
    end

    def active_subscriptions
      QuickBilling.models[:subscription].for_account(self.id).active
    end

    # ACCESSORS

    def state
      if self.balance < 0 && self.balance_overdue_at < Time.now
        return STATES[:delinquent]
      else
        return STATES[:paid]
      end
    end

    # ACTIONS

    def ensure_customer_id!
      return self.customer_id unless self.customer_id.blank?
      result = QuickBilling.platform.create_customer({id: self.id.to_s, email: self.user.email})
      if result[:success]
        self.customer_id = result[:id]
        self.platform = QuickBilling.options[:platform]
        self.save
      else
        raise "Could not create customer!"
      end
      return self.customer_id
    end

    def save_credit_card(opts)
      result = QuickBilling.platform.save_credit_card(
        token: opts[:token],
        customer_id: self.ensure_customer_id!,
        number: opts[:number].to_s,
        expiration_date: opts[:expiration_date]
      )
      self.update_payment_methods
      return result
    end

    def delete_credit_card(opts)
      result = QuickBilling.platform.delete_credit_card(token: opts[:token])
      self.update_payment_methods
      return result
    end

    def update_payment_methods
      result = QuickBilling.platform.list_payment_methods(self.ensure_customer_id!)
      if result[:success]
        self.payment_methods = result[:data].collect(&:to_api)
        self.save
      end
    end

    def update_balance
      # iterate all transactions
      old_bal = self.balance

      new_bal = 0
      QuickBilling.models[:transaction].completed.for_account(self.id).each do |tr|
        if tr.type?(:charge) || tr.type?(:refund)
          new_bal += tr.amount
        elsif tr.type?(:payment) || tr.type?(:credit)
          new_bal -= tr.amount
        end
      end


      if old_bal >= 0 && new_bal < 0
        # if old balance was not negative, set balance_overdue_at
        self.balance_overdue_at = Time.now + 14.days
      elsif old_bal < 0 && new_bal >= 0
        # if balance is now not negative, reset balance_overdue_at
        self.balance_overdue_at = nil
      end

      self.balance = new_bal

      self.save
      return self.balance
    end

    def modify_balance!(amt)
      self.inc(:bl, amt)
    end

    def subscribe_to_single_plan!(opts)
      plan_key = opts[:plan_key]
      as = self.active_subscription
      as.cancel! unless as.nil?
      sub = QuickBilling.models[:subscription].subscribe_to_plan(self, plan_key)
    end

    def enter_payment!(amt = nil)
      self.last_payment_attempted_at = Time.now
      self.save

      amt ||= self.update_balance   # ensure balance up to date

      return {success: false, error: 'Payment amount must be greater than $2.'} if amt <= 200
      result = QuickBilling.models[:transaction].enter_payment!(self, amt)
      Job.run_later :billing, self, :handle_payment_attempted
      return {success: true}
    end

    def handle_payment_attempted
    end

    def update_platform_info
      return if self.customer_id.nil?
      cust = QuickBilling.platform.find_customer(self.customer_id)
      if cust.nil?
        self.customer_id = nil
      end
      self.update_payment_methods
    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id
      ret[:balance] = self.balance
      ret[:payment_methods] = self.payment_methods
      ret[:active_subscriptions] = self.active_subscriptions.collect(&:to_api)
      return ret
    end

  end

end
