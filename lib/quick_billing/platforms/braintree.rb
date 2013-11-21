module QuickBilling

  module Platforms

    module Braintree
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
          return {success: false, orig: result}
        end
      end

      def self.list_customer_payment_methods(customer_id, opts)
        cust = self.find_customer(customer_id)
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
          return {success: false, error: tr.status, orig: result}
        end
      end


    end

  end

end


