module QuickBilling

  # Process for building invoice:
  # 1. Line items for subtotal (including shipping)
  # 2. Discounts (percent or amount)
  # 3. Taxes and Fees (not applicable to discounts)
  module Invoice

    STATES = {open: 1, charged_to_account: 2, voided: 3}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_invoice_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model

          field :ds, as: :description, type: String
          field :st, as: :state, type: Integer
          field :p_st, as: :period_start, type: Time
          field :p_end, as: :period_end, type: Time
          field :its, as: :items, type: Array, default: []
          field :dcs, as: :discounts, type: Array, default: []
          field :txs, as: :taxes, type: Array, default: []

          belongs_to :subscription, :foreign_key => :sid, :class_name => QuickBilling.Subscription.to_s
          belongs_to :account, :foreign_key => :aid, :class_name => QuickBilling.Account.to_s

          mongoid_timestamps!

          enum_methods! :state, STATES

        end
      end

      def build_from_subscription(sub)
        inv = Invoice.new
        inv.subscription = sub
        inv.account = sub.account
        inv.state! :open

        # add plan
        inv.add_item("#{sub.plan.name} Plan (Quantity: #{sub.quantity})", sub.amount)

        # add discounts
        self.discounts.each do |adj|
          inv.add_discount(adj.name, {amount: adj.amount, percent: adj.percent})
        end

        # add tax if any
        self.taxes.each do |adj|
          inv.add_tax(adj.name, {amount: adj.amount, percent: adj.percent})
        end

      end

    end

    ## INSTANCE METHODS

    def add_item(desc, amount, opts={})
      itm = opts.merge({description: desc, amount: amount})
      self.items << itm
    end

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:description] = self.description
      ret
    end


  end

  class InvoiceItem
    attr_accessor :amount, :description, :adjustment_id
  end

end
