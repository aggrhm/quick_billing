module QuickBilling

  module Payment
    include QuickBilling::ModelBase
    STATES = {entered: 1, processing: 2, completed: 3, void: 4, error: 5}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_payment_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :tk, as: :token, type: String
          field :st, as: :state, type: Integer
          field :st_at, as: :state_changed_at, type: Time
          field :pm, type: Hash
          field :am, as: :amount, type: Integer
          field :ds, as: :description, type: String
          field :sa, as: :status, type: String

          belongs_to :account, :foreign_key => :aid, :class_name => QuickBilling.classes[:account]

          mongoid_timestamps!

          enum_methods! :state, STATES

          define_method :payment_method do
            self.pm.nil? ? nil : QuickBilling::PaymentMethod.new(self.pm)
          end

          define_method :payment_method= do |val|
            if val.nil?
              self.pm = nil
            elsif val.is_a? QuickBilling::PaymentMethod
              self.pm = val.to_hash
            elsif val.is_a? Hash
              self.pm = val
            else
              raise "Cannot convert #{val.class.to_s} to mongo"
            end
          end

        end

        scope :for_account, lambda {|aid|
          where(aid: aid)
        }

        scope :pending, lambda {
          where(:st => {'$in' => [STATES[:entered], STATES[:processing]]})
        }

        scope :with_error, lambda {
          where(:st => STATE[:error])
        }

      end

      def send_payment!(opts)
        acct = opts[:account]
        payment_method = opts[:payment_method]
        amt = opts[:amount]
        return {success: false, error: "Cannot charge non-positive amount."} if amt < 0

        begin
          success = false
          p = self.new
          p.state! :entered
          p.amount = amt
          p.account = acct
          p.payment_method = payment_method
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
      pm = self.payment_method

      result = QuickBilling.platform.send_payment(
        amount: self.amount,
        payment_method: pm
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
      ret[:amount] = self.amount
      ret[:created_at] = self.created_at.to_i
      ret[:payment_method] = self.payment_method.nil? ? nil : self.payment_method.to_api
      ret[:state] = self.state
      return ret
    end

  end

end
