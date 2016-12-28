module QuickBilling

  module Payment
    STATES = {entered: 1, processing: 2, completed: 3, void: 4, error: 5}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_payment!
        include QuickBilling::ModelBase
        include QuickScript::Model
        if self.respond_to?(:field)
          field :token, type: String
          field :state, type: Integer
          field :state_changed_at, type: Time
          field :payment_method_data, type: Hash
          field :amount, type: Integer
          field :description, type: String
          field :status, type: String

          field :account_id, type: Integer

          timestamps!
        end

        belongs_to :account, :class_name => QuickBilling.classes[:account]
        enum_methods! :state, STATES

        scope :for_account, lambda {|aid|
          where(account_id: aid)
        }
        scope :pending, lambda {
          where(:st => [STATES[:entered], STATES[:processing]])
        }
        scope :with_error, lambda {
          where(:st => STATE[:error])
        }
      end

      def send_payment!(opts)
        acct = opts[:account]
        pm_id = opts[:payment_method_id]
        pm = PaymentMethod.find(pm_id)
        return {success: false, error: "Payment method not found."} if pm.nil?
        amt = opts[:amount]
        return {success: false, error: "Cannot charge non-positive amount."} if amt < 0

        begin
          success = false
          p = self.new
          p.state! :entered
          p.amount = amt
          p.account = acct
          p.payment_method_data = pm.to_api.stringify_keys
          # TODO: if payment doesn't clear immediately, enter transaction as processing and lookup later when transaction completes. If transaction errors, make processing transaction void and update balance
          if p.save
            res = p.process_payment!
            if res[:success]
              return {success: true, data: p}
            else
              return {success: false, data: p, error: res[:error]}
            end
          else
            return {success: false, data: p, error: "Payment could not be entered"}
          end
        rescue => e
          p.state! :error
          p.status = e.message
          p.status << "\n" + e.backtrace.join("\n\t")
          p.save
          return {success: false, data: p, error: "An error occurred processing this payment. Please do not re-attempt, an admin will contact you."}
        end
      end

    end

    ## INSTANCE METHODS

    def process_payment!
      acct = self.account

      result = QuickBilling.platform.send_payment(
        amount: self.amount,
        payment_method: self.payment_method_data["token"]
      )

      if !result[:success]
        self.state! :error
        self.token = result[:id]
        self.status = result[:error]
        self.save
        self.report_event('attempted')
        self.report_event('error', action: 'process_payment', message: result[:error])
        return {success: false, error: result[:error]}
      end

      begin
        self.state! :completed
        self.token = result[:id]
        self.save
        self.report_event('attempted')
        self.report_event('completed')

        # enter transaction
        result = QuickBilling.Transaction.enter_completed_payment!(self)
        if result[:success]
          return {success: true}
        else
          return {success: false, error: result[:error]}
        end
      rescue => ex
        QuickBilling.platform.void_payment(result[:id])
        self.state! :error
        self.token = result[:id]
        self.save
        self.report_event('error', action: 'process_payment', message: ex.message, backtrace: ex.backtrace)
        return {success: false, error: "An error occurred processing this payment"}
      end
    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:state] = self.state
      ret[:amount] = self.amount
      ret[:created_at] = self.created_at.to_i
      ret[:payment_method_data] = self.payment_method_data
      return ret
    end

  end

end
