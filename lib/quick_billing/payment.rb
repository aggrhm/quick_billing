module QuickBilling

  module Payment
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
          field :pm, as: :payment_method, type: Hash
          field :am, as: :amount, type: Integer
          field :ds, as: :description, type: String
          field :sa, as: :status, type: String
          field :aid, as: :accountable_id, type: Moped::BSON::ObjectId
          field :acl, as: :accountable_class, type: String

          mongoid_timestamps!

          enum_methods! :state, STATES

        end

        scope :for_accountable, lambda {|aid|
          where(aid: aid)
        }

        scope :pending, lambda {
          where(:st => {'$in' => [STATES[:entered], STATES[:processing]]})
        }

        scope :with_error, lambda {
          where(:st => STATE[:error])
        }

      end

      def send_payment!(accountable, payment_method, amt, opts={})
        return {success: false, error: "Cannot charge non-positive amount."} if amt < 0

        begin
          success = false
          p = self.new
          p.state! :entered
          p.amount = amt
          p.accountable = accountable
          p.payment_method = payment_method
          if p.save
            if p.process_payment!
              # notify accountable
              result = p.accountable.handle_payment_completed(p)
              if result[:success]
                success = true
              else
                success = false
                p.state! :error
                p.status = result[:error]
                p.save
              end
            end
          end

          Job.run_later :billing, accountable, :handle_payment_attempted, [p.id]
          return {success: success, data: p, error: p.status}
        rescue Exception => e
          p.state! :error
          p.status = e.message
          p.status << "\n" + e.backtrace.join("\n\t")
          p.save
          return {success: false, data: p, error: "An error occurred processing this payment. Please do not re-attempt, an admin will contact you."}
        end
      end

    end

    ## INSTANCE METHODS

    def accountable=(val)
      self.accountable_id = val.id
      self.accountable_class = val.class.to_s
      return val
    end

    def accountable
      base = Object.const_get(self.accountable_class)
      base.find(self.accountable_id)
    end

    def process_payment!
      acct = self.accountable
      pm = self.payment_method

      result = QuickBilling.platform.send_payment(
        amount: self.amount,
        payment_method: pm
      )

      if result[:success]
        self.state! :completed
        self.token = result[:id]
        self.save
        Job.run_later :billing, self, :handle_completed
        return true
      else
        self.state! :error
        self.token = result[:id]
        self.status = result[:error]
        self.save
        Job.run_later :billing, self, :handle_error
        return false
      end
    end

    def handle_completed

    end

    def handle_error

    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:amount] = self.amount
      ret[:created_at] = self.created_at.to_i
      ret[:payment_method] = self.payment_method
      ret[:state] = self.state
      return ret
    end

  end

end
