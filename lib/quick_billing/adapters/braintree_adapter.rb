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

      def self.save_payment_method(opts)
        req = {
          token: opts[:token], 
          customer_id: opts[:customer_id],
          payment_method_nonce: opts[:payment_method_nonce]
        }
        if req[:token].blank?
          result = Braintree::PaymentMethod.create(req)
        else
          result = Braintree::PaymentMethod.update(req[:token], req)
        end
        if result.success?
          return {success: true, data: result.payment_method, token: result.payment_method.token, orig: result}
        else
          return {success: false, data: result.payment_method, error: result.message}
        end
      end

      def self.delete_payment_method(opts)
        begin
          result = Braintree::PaymentMethod.delete(opts[:token])
          if result == true || result.success?
            return {success: true, token: pm.token, orig: result}
          else
            return {success: false, error: 'Payment method could not be removed.', orig: result}
          end
        rescue Braintree::NotFoundError => e
          return {success: false, error: "Payment method could not be found.", error_code: QuickBilling::ERROR_CODES[:resource_not_found], orig: result}
        rescue => e
          return {success: false, error: 'An error occurred removing payment method.', orig: result}
        end
      end

      def self.list_payment_methods(customer_id, opts={})
        cust = self.find_customer(customer_id)
        return {success: false, error: "Customer not found"} if cust.nil?
        data = cust.payment_methods
        return {success: true, data: data}
      end

      def self.find_customer(customer_id)
        Braintree::Customer.find(customer_id)
      end

      def self.send_payment(opts)
        result = Braintree::Transaction.sale(
          amount: (opts[:amount] / 100.0).to_s,
          payment_method_token: opts[:payment_method_token],
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

      def self.void_payment(token)
        result = Braintree::Transaction.void(token)
        if result.success?
          return {success: true, id: token}
        else
          return {success: false, error: result.message, orig: result}
        end
      end


    end

  end

end


