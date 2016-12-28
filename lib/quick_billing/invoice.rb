module QuickBilling

  # Process for building invoice:
  # 1. Line items for subtotal (including shipping)
  # 2. Discounts (percent or amount)
  # 3. Taxes and Fees (not applicable to discounts)
  module Invoice
    include QuickBilling::ModelBase

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

      def quick_billing_invoice!
        include QuickScript::Model
        if self.respond_to?(:field)
          field :description, type: String
          field :state, type: Integer
          field :period_start, type: Time
          field :period_end, type: Time
          field :charged_amount, type: Integer

          field :subscription_id, type: Integer
          field :account_id, type: Integer

          timestamps!
        end

        belongs_to :subscription, class_name: QuickBilling.classes[:subscription]
        belongs_to :account, class_name: QuickBilling.classes[:account]
        has_many :entries, foreign_key: :invoice_id, class_name: QuickBilling.classes[:entry]

        enum_methods! :state, STATES

        scope :with_state, lambda {|st|
          where(st: STATES[st.to_sym])
        }
      end

      def from_entries
        inv = self.new
        inv.state! :open
        inv.parse_entries
        return inv
      end

    end

    ## INSTANCE METHODS

    def parse_entries
      raise "Needs refactoring"
      @entries = []
      entries.each do |entry|
        next if !entry.invoiceable?(true)
        itm = entry.to_line_item
        self.items << itm
        @entries << entry
      end
      self.calculate_totals
      self.items
    end

    def ordered_items
      self.entries.sort_by {|e| Entry::SOURCES_SORT_ORDER.index(e.source) || 100 }
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
      self.entries.select{|e| e.source != Entry::SOURCES[:discount] && e.source != Entry::SOURCES[:tax]}.each do |e|
        sum += e.total_amount
      end
      @subtotal = sum

      # add discounts
      sub = @subtotal
      sum = 0
      self.entries.select{|e| e.source == Entry::SOURCES[:discount]}.each do |e|
        sum += e.total_amount(sub)
      end
      @discount_total = sum
      # don't let discount be greater than subtotal
      @discount_total = @subtotal if @discount_total.abs > @subtotal.abs

      # then taxes
      sub = @discount_total
      sum = 0
      self.entries.select{|e| e.source == Entry::SOURCES[:tax]}.each do |itm|
        sum += e.total_amount(sub)
      end
      @tax_total = sum

      @total = @subtotal + @discount_total + @tax_total
      return
    end

    # TRANSACTIONS

    def charge_to_account!(acct)
      ttl = self.total
      res = QuickBilling.Transaction.enter_charge!(acct, ttl, {
        invoice: self,
        subscription: self.subscription,
        description: self.description
      })
      if res[:success]
        self.state! :charged
        self.charged_amount = ttl
        self.save
        Job.run_later :billing, self, :update_invoice_stats_for_entries
        self.report_event('charged')
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
      self.report_event('voided')
      return {success: true}
    end

    def update_invoice_stats_for_entries
      self.items.each do |item|
        entry = QuickBilling.Entry.find(item["entry_id"])
        next if entry.nil?
        entry.invoice_count(true)
      end
    end

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:subscription_id] = self.subscription_id ? self.subscription_id.to_s : nil
      ret[:description] = self.description
      ret[:state] = self.state
      ret[:subtotal] = self.subtotal
      ret[:total] = self.total
      ret[:entries] = self.ordered_entries
      ret[:created_at] = self.created_at.to_i
      ret[:period_start] = self.period_start.to_i
      ret[:period_end] = self.period_end.to_i

      return ret
    end


  end

end
