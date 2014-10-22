module QuickBilling

  # Process for building invoice:
  # 1. Line items for subtotal (including shipping)
  # 2. Discounts (percent or amount)
  # 3. Taxes and Fees (not applicable to discounts)
  module Invoice

    STATES = {open: 1, charged: 2, paid: 3, voided: 4}

    def self.included(base)
      base.extend ClassMethods
    end

    def self.adjust_amount(amt, item)
      ret = amt
      if !item["amount"].nil?
        ret += self.amount
      end
      if !item["percent"].nil?
        c = amt * (item["percent"] / 100.0)
        ret += c
      end
      return ret
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

          belongs_to :subscription, foreign_key: :sid, class_name: QuickBilling.Subscription.to_s
          belongs_to :account, foreign_key: :aid, class_name: QuickBilling.Account.to_s

          mongoid_timestamps!

          enum_methods! :state, STATES

          scope :with_entry, lambda {|eid|
            where("its.entry_id" => eid)
          }
          scope :is_state, lambda {|st|
            where(st: STATES[st.to_sym])
          }

        end
      end

    end

    ## INSTANCE METHODS

    def parse_entries(entries)
      entries.each do |entry|
        next if !entry.invoice_limit.nil? && entry.invoices_count >= entry.invoice_limit
        itm = {"source" => entry.source, "description" => entry.description, "amount" => entry.amount, "percent" => entry.percent, "quantity" => entry.quantity, "entry_id" => entry.id}
        self.items << itm
      end
      self.calculate_totals
      self.items
    end

    def charged_transaction
      QuickBilling.Transaction.for_invoice(self.id).completed.first
    end

    def subtotal
      calculate_totals if @subtotal.nil?
      @subtotal
    end
    def total
      calculate_totals if @total.nil?
      @total
    end

    def calculate_totals
      # sum only line items
      sum = 0
      self.items.select{|itm| itm["source"] != Entry::SOURCES[:discount] && itm["source"] != Entry::SOURCES[:tax]}.each do |itm|
        itm["total"] = (itm["quantity"] || 0) * (itm["amount"] || 0)
        sum += itm["total"]
      end
      @subtotal = sum

      # add discounts
      sub = @subtotal
      sum = 0
      self.items.select{|itm| itm["source"] == Entry::SOURCES[:discount]}.each do |itm|
        amt = itm["amount"] || 0
        per = itm["percent"] ? ( (itm["percent"] / 100.0) * sub ) : 0
        itm["total"] = (amt + per).round(2)
        sum += itm["total"]
      end
      @discount_total = sum
      # don't let discount be greater than subtotal
      @discount_total = @subtotal if @discount_total.abs > @subtotal.abs

      # then taxes
      sub = @discount_total
      sum = 0
      self.items.select{|itm| itm["source"] == Entry::SOURCES[:tax]}.each do |itm|
        amt = itm["amount"] || 0
        per = itm["percent"] ? ( (itm["percent"] / 100.0) * sub ) : 0
        itm["total"] = (amt + per).round(2)
        sum += itm["total"]
      end
      @tax_total = sum

      @total = @subtotal + @discount_total + @tax_total
      return
    end

    # TRANSACTIONS

    def charge_to_account!(acct)
      res = QuickBilling.Transaction.enter_charge!(acct, self.total, {
        invoice: self,
        subscription: self.subscription,
        description: self.description
      })
      if res[:success]
        self.state! :charged
        self.save
        Job.run_later :billing, self, :handle_charged
      end
      return res
    end

    def void!
      # void the transaction
      tr = self.charged_transaction
      if !tr.nil?
        tr.void!
      end
      self.state! :voided
      self.save
      return {success: true}
    end

    def update_invoice_stats_for_entries
      self.items.each do |item|
        entry = QuickBilling.Entry.find(item["entry_id"])
        if !entry.nil? && !entry.invoice_limit.nil?
          count = Invoice.is_state(:charged).with_entry(entry.id)
          entry.invoices_left = entry.invoice_limit - count
          entry.save
        end
      end
    end

    def handle_charged
      Job.run_later :billing, self, :update_invoice_stats_for_entries
    end

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:description] = self.description
      ret[:subtotal] = self.subtotal
      ret[:total] = self.total
      ret[:items] = self.items
      return ret
    end


  end

  class InvoiceItem
    attr_accessor :amount, :description, :adjustment_id

  end

end
