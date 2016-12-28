module QuickBilling

  module PaymentMethod

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_payment_method!
        include QuickBilling::ModelBase
        include QuickScript::Model

        if self.respond_to?(:field)
          field :platform, type: String
          field :customer_id, type: String
          field :payment_type, type: Integer
          field :token, type: String
          field :masked_number, type: String
          field :last_4, type: String
          field :expiration_date, type: String
          field :card_type, type: String

          field :account_id, type: Integer
          timestamps!
        end

        belongs_to :account, class_name: QuickBilling.classes[:account]

        scope :for_account, lambda {|aid|
          where(account_id: aid)
        }
        scope :with_token, lambda {|t|
          where(token: t)
        }

        validate do
          errors.add(:account, "Account not specified.") if self.account_id.blank?
          errors.add(:platform, "Platform not specified.") if self.account_id.blank?
          errors.add(:token, "Token not specified.") if self.token.blank?
        end

      end

    end

    ## ACTIONS

    def update_as_action!(opts)
      new_record = self.new_record?
      if !new_record
        return {success: false, error: "You cannot edit a payment method. You must delete it and create another."}
      end
      acct = QuickBilling.Account.find(opts[:account_id])
      self.account = acct
      opts[:customer_id] = self.ensure_customer_id!
      res = QuickBilling.platform.save_payment_method(opts)
      pm = res[:data]
      token = res[:token]
      success = res[:success]
      error = res[:error]
      if success
        self.from_platform_payment_method(pm)
        success = self.save
        error = self.error_message if !success
      end
      return {success: success, data: self, error: error, new_record: true}
    rescue => e
      QuickScript.log_exception(e)
      if token
        QuickBilling.platform.delete_payment_method(token: token)
        self.destroy
      end
      return {success: false, data: self, error: "An unexpected error occurred", new_record: true}
    end

    def delete_as_action!(opts)
      opts[:token] = self.token
      res = QuickBilling.platform.delete_payment_method(opts)
      can_delete = res[:success] || res[:error_code] == QuickBilling::ERROR_TYPES[:resource_not_found]
      error = nil
      success = true
      if can_delete
        self.destroy
      else
        success = false
        error = res[:error]
      end
      return {success: success, data: self, error: error}
    end

    def from_platform_payment_method(pm)
      if pm.is_a?(Braintree::PaymentMethod)
        from_braintree_payment_method(pm)
      else
        raise "Payment method unknown"
      end
    end

    def from_braintree_payment_method(pm)
      self.platform = 'braintree'
      self.customer_id = pm.customer_id
      self.payment_type = QuickBilling::PAYMENT_TYPES[:credit_card]
      self.token = pm.token
      self.masked_number = pm.masked_number
      self.last_4 = pm.last_4
      self.expiration_date = pm.expiration_date
      self.card_type = pm.card_type
    end

  end

end
