module QuickBilling

  module Adapters

    module BraintreeAdapter
      ## CUSTOMERS

      def self.create_customer(opts)
        result = Braintree::Customer.create(opts)
        if result.success?
          return {success: true, id: result.customer.id, orig: result}
        else
          return {success: false, orig: result}
        end
      end

      ## ACCOUNTS

      def self.save_credit_card(opts)
        if opts[:token].blank?
          result = Braintree::CreditCard.create(opts.slice(:customer_id, :number, :expiration_date, :cvv))
        else
          result = Braintree::CreditCard.update(opts.slice(:token, :customer_id, :number, :expiration_date, :cvv))
        end
        if result.success?
          pm = PaymentMethod.from_braintree_credit_card(result.credit_card)
          return {success: true, id: result.credit_card.token, data: pm, orig: result}
        else
          return {success: false, error: result.message, orig: result}
        end
      end

      def self.delete_credit_card(opts)
        begin
          result = Braintree::CreditCard.delete(opts[:token])
          if result == true || result.success?
            pm = PaymentMethod.new(token: opts[:token])
            return {success: true, id: pm.token, data: pm, orig: result}
          else
            return {success: false, error: 'Credit card could not be found.', orig: result}
          end
        rescue Exception => e
            return {success: false, error: 'Credit card could not be found.', orig: result}
        end
      end

      def self.list_payment_methods(customer_id, opts={})
        cust = self.find_customer(customer_id)
        return {success: false, error: "Customer not found"} if cust.nil?
        data = cust.credit_cards.collect {|card|
          PaymentMethod.from_braintree_credit_card(card)
        }
        return {success: true, data: data}
      end

      def self.find_customer(customer_id)
        Braintree::Customer.find(customer_id)
      end

      def self.send_payment(opts)
        result = Braintree::Transaction.sale(
          amount: (opts[:amount] / 100.0).to_s,
          customer_id: opts[:customer_id],
          recurring: true,
          options: {
            submit_for_settlement: true
          }
        )
        tr = result.transaction
        if result.success?
          return {success: true, id: tr.id, status: tr.status, orig: result}
        else
          return {success: false, error: result.message, orig: result}
        end
      end


    end

  end

end


