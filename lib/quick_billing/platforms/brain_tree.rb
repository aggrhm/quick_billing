module QuickBilling

  module Platforms

    module BrainTree
      ## CUSTOMERS

      def self.create_customer(opts)
        result = BrainTree::Customer.create(opts)
        if result.success?
          return {success: true, data: result.customer.id, orig: result}
        else
          return {success: false, orig: result}
        end
      end

      ## ACCOUNTS

      def self.save_credit_card(opts)
        if opts[:token].blank?
          result = BrainTree::CreditCard.create(opts.slice(:customer_id, :number, :expiration_date, :cvv))
        else
          result = BrainTree::CreditCard.update(opts.slice(:token, :customer_id, :number, :expiration_date, :cvv))
        end
        if result.success?
          pm = PaymentMethod.from_braintree_credit_card(result.card)
          return {success: true, data: pm, orig: result}
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
        BrainTree::Customer.find(customer_id)
      end


    end

  end

end


