module QuickBilling

  module PaymentMethod

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_payment_method!
        include QuickScript::Eventable
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

        enum_methods! :payment_type, QuickBilling::PAYMENT_TYPES

        scope :for_account, lambda {|aid|
          where(account_id: aid)
        }
        scope :with_account_id, lambda {|aid|
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
      opts[:customer_id] = acct.customer_id
      res = QuickBilling.platform.save_payment_method(opts)
      pm = res[:data]
      token = res[:token]
      success = res[:success]
      error = res[:error]
      pf = res[:platform]
      if success
        self.from_platform_payment_method(pf, pm)
        success = self.save
        error = self.error_message if !success
        report_event 'updated', new_record: new_record
        if opts[:set_as_default] || self.account.default_payment_method_id.blank?
          self.account.update_attribute :default_payment_method_id, self.id
        end
      end
      return {success: success, data: self, error: error, new_record: true}
    rescue => e
      QuickScript.log_exception(e)
      if token
        QuickBilling.platform.delete_payment_method(token: token)
        self.destroy
      end
      return {success: false, data: self, error: "An error occurred updating your payment method. Please try again.", new_record: true}
    end

    def delete_as_action!(opts)
      opts[:token] = self.token
      res = QuickBilling.platform.delete_payment_method(opts)
      can_delete = res[:success] || res[:error_code] == QuickBilling::ERROR_CODES[:resource_not_found]
      error = nil
      success = true
      if can_delete
        self.destroy
        if self.account.default_payment_method_id == self.id
          nd = self.account.payment_methods.last
          self.account.update_attribute :default_payment_method_id, (nd ? nd.id : nil)
        end
      else
        success = false
        error = res[:error]
      end
      return {success: success, data: self, error: error}
    end

    def from_platform_payment_method(platform, pm)
      if platform == QuickBilling::PAYMENT_PLATFORMS[:braintree]
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

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:account_id] = self.account_id.to_s
      ret[:platform] = self.platform
      ret[:payment_type] = self.payment_type
      ret[:masked_number] = self.masked_number
      ret[:last_4] = self.last_4
      ret[:expiration_date] = self.expiration_date
      ret[:card_type] = self.card_type
      ret[:created_at] = self.created_at.to_i
      return ret
    end

  end

end
