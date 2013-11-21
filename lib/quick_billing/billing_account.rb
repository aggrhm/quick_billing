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

          scope :with_negative_balance, lambda {
            where('bl' => {'$lt' => 0})
          }

          scope :payment_attempt_ready, lambda {
            where('pa_at' => {'$lt' => 1.day.ago})
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
        self.with_negative_balance.payment_attempt_ready.each do |acct|
          QuickUtils.unit_of_work do
            Rails.logger.info "#{Time.now.to_s}: Entering payment for accountable #{acct}."
            acct.enter_payment!
          end
        end
      end

    end

    ## INSTANCE METHODS
    
    # returns first active subscription
    def active_subscription
      self.active_subscriptions.first
    end

    def active_subscriptions
      Subscription.for_account(self.id).active.first
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
      return unless self.customer_id.nil?
      result = QuickBilling.platform.create_customer({id: self.id.to_s, email: self.user.email})
      if result[:success]
        self.customer_id = result[:id]
        self.platform = QuickBilling.options[:platform]
        self.save
      else
        raise "Could not create customer!"
      end
    end

    def save_credit_card(opts)
      self.ensure_customer_id!
      result = QuickBilling.platform.save_credit_card(
        token: opts[:token],
        customer_id: self.customer_id,
        number: opts[:number].to_s,
        expiration_date: opts[:expiration_date]
      )
      if result[:success]
        self.update_customer_accounts
      end
      return result
    end

    def update_customer_accounts
      self.ensure_customer_id!
      result = QuickBilling.platform.list_customer_accounts(self.customer_id)
      if result[:success]
        self.payment_methods = result[:data].collect(&:to_api)
        self.save
      end
    end

    def update_account_balance
      # iterate all transactions
      old_bal = self.account_balance

      new_bal = 0
      Transaction.for_accountable(self.id).each do |tr|
        if tr.state? :charge || tr.state? :refund
          new_bal -= tr.amount
        elsif tr.state? :payment || tr.state? :credit
          new_bal += tr.amount
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
    end

    def subscribe_to_single_plan(opts)
      plan_key = opts[:plan_key]
      as = self.active_subscription
      as.cancel! unless as.nil?
      sub = Subscription.subscribe_to_plan(user, plan_key)
    end

    def enter_payment!(amt = nil)
      amt ||= self.account_balance
      amt = amt.abs

      result = Transaction.enter_payment!(self, amt)
      if result[:success]
        Job.run_later :meta, self, :update_account_balance
      end
      self.last_payment_attempted_at = Time.now
      self.save
    end

    def to_api
      ret = {}
      ret[:id] = self.id
      ret[:balance] = self.balance
      ret[:payment_methods] = self.payment_methods
      ret[:subscriptions] = self.active_subscriptions.collect(&:to_api)
      return ret
    end

  end

end
