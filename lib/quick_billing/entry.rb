module QuickBilling

  # This model represents a billable item pre-invoice. By specifying the invoice_limit and
  # invoices_left, we can use these to generate each invoice, knowing which Entries are
  # still invoiceable (recurring or once). Any parent model should determine which Entries
  # assigned to it are still invoiceable and create a new invoice with them, remembering to
  # decrement the invoices_left attribute.
  module Entry
    include QuickBilling::ModelBase

    SOURCES = {discount: 1, tax: 2, prorate: 3, product: 4}
    SOURCES_SORT_ORDER = [4, 3, 1, 2]
    STATES = {valid: 1, voided: 2}

    def self.included(base)
      base.send :include, QuickBilling::ModelBase
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_entry!
        include QuickScript::Model
        if self.respond_to?(:field)
          field :description, type: String
          field :state, type: Integer, default: 1
          field :source, type: Integer
          field :amount, type: Integer
          field :percent, type: Integer
          field :invoices_left, type: Integer
          field :invoice_count, type: Integer, default: 0    # invoice count
          field :invoice_limit, type: Integer
          field :quantity, type: Integer, default: 1
          field :meta, type: Hash, default: {}

          field :subscription_id, type: Integer
          belongs_to :subscription, class_name: QuickBilling.classes[:subscription]

          field :account_id, type: Integer
          belongs_to :account, class_name: QuickBilling.classes[:account]

          field :coupon_id, type: Integer
          belongs_to :coupon, class_name: QuickBilling.classes[:coupon]

          field :product_id, type: Integer
          belongs_to :product, class_name: QuickBilling.classes[:product]

          timestamps!

          enum_methods! :source, SOURCES
          enum_methods! :state, STATES

          scope :for_coupon, lambda {|cid|
            where(coupon_id: cid)
          }
          scope :for_product, lambda {|pid|
            where(product_id: pid)
          }
          scope :for_account, lambda {|aid|
            where(account_id: aid)
          }
          scope :for_subscription, lambda {|sid|
            where(subscription_id: sid)
          }
          scope :is_discount, lambda {
            where(source: SOURCES[:discount])
          }
          scope :is_tax, lambda {
            where(source: SOURCES[:tax])
          }
          scope :is_prorate, lambda {
            where(source: SOURCES[:prorate])
          }
          scope :is_product, lambda {
            where(source: SOURCES[:product])
          }
          scope :is_valid, lambda {
            where("state != 2")
          }
          scope :invoiceable, lambda {
            is_valid.where("invoices_left is null OR invoices_left > 0")
          }
          scope :invoiced, lambda {
            where("invoice_count > 0")
          }
        end

        validate do
          errors.add(:amount, "Must specify an amount or a percent") if self.amount.nil? && self.percent.nil?
          errors.add(:quantity, "Quantity must be greater than 0") if self.quantity <= 0
        end

      end

      def build_list(data)
        data.collect {|d|
          if d.is_a?(String)
            self.find(d)
          elsif d.is_a?(Hash)
            self.build_from_hash(d)
          elsif d.is_a?(self)
            d
          end
        }.select{|e| !e.nil?}
      end

      def build_from_hash(opts)
        opts = opts.symbolize_keys
        e = self.find(opts[:id]) unless opts[:id].blank?
        if e.nil?
          case opts[:source]
          when SOURCES[:product]
            e = self.build_from_product(opts[:product_id], opts[:quantity].to_i)
          when SOURCES[:discount]
            e = self.build_from_coupon(opts[:coupon_id])
          end
        end
        return e
      end

      def build_from_coupon(coupon)
        coupon = QuickBilling.Coupon.find_with_code(coupon) unless coupon.is_a?(QuickBilling.Coupon)
        return nil if coupon.nil?
        e = self.new
        e.source! :discount
        e.coupon = coupon
        e.description = "Coupon (#{coupon.code})"
        e.amount = coupon.amount
        e.percent = coupon.percent
        e.invoices_left = coupon.max_uses
        e.invoice_limit = coupon.max_uses
        e.state! :valid
        return e
      end

      def build_from_product(product, quantity)
        product = QuickBilling.Product.find(product) unless product.is_a?(QuickBilling.Product)
        return nil if product.nil?
        e = self.new
        e.source! :product
        e.product = product
        e.description = "#{product.name}"
        e.amount = product.price
        e.quantity = quantity
        e.state! :valid
        return e
      end

    end

    def usable?
      self.max_uses.nil? || (self.times_used < self.max_uses)
    end

    def invoiced?
      self.invoice_count(true) > 0
    end

    def invoiceable?(reload=false)
      return false if self.state?(:voided)
      return true if self.invoice_limit.nil?
      return self.invoice_count(reload) < self.invoice_limit
    end

    def invoice_count(reload=false)
      if reload || self.ic.nil?
        # TODO: Need to look up Entries linked to this one that have invoice_id
        raise "Needs fixing"
        #count = QuickBilling.Invoice.is_state(:charged).with_entry(self.id).count
        if !self.invoice_limit.nil?
          self.invoices_left = self.invoice_limit - count
        end
        self[:invoice_count] = count
        self.save_if_persisted
      end
      self[:invoice_count]
    end

    def save_if_persisted
      if self.new_record?
        return self.valid?
      else
        return self.save
      end
    end

    def adjust_amount(a)
      if !self.amount.nil?
        return a + self.amount
      elsif !self.percent.nil?
        c = a * (self.percent / 100.0)
        return a + c
      else
        return a
      end

    end

    def total_amount(ref=nil)
      if self.percent.present?
        ret = (ref * (self.percent / 100.0)).round(2)
      else
        ret = 0
      end
      return ret + self.amount * self.quantity
    end

    def adjustment_str
      if !self.amount.nil?
        amt = Money.new(self.amount * self.quantity, "USD")
        return amt.format
      elsif !self.percent.nil?
        return "#{self.percent}% #{self.percent < 0 ? 'off' : 'additional'}"
      else
        return "-"
      end
    end

    def to_line_item
      ret = {}
      ret['id'] = self.id.to_s
      ret['entry_id'] = self.id.to_s
      ret['source'] = self.source
      ret['description'] = self.description
      ret['amount'] = self.amount
      ret['percent'] = self.percent
      ret['quantity'] = self.quantity
      ret['adjustment_str'] = self.adjustment_str
      ret['invoice_limit'] = self.invoice_limit
      ret['meta'] = self.meta
      if !self.product.nil?
        ret['product'] = self.product.to_api.stringify_keys
      end
      if !self.coupon.nil?
        ret['coupon'] = self.coupon.to_api.stringify_keys
      end
      return ret
    end

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s unless self.new_record?
      ret[:description] = self.description
      ret[:source] = self.source
      ret[:amount] = self.amount
      ret[:percent] = self.percent
      ret[:quantity] = self.quantity
      ret[:product] = self.product.to_api if self.product
      ret[:product_id] = self.product_id.to_s
      ret[:coupon] = self.coupon.to_api if self.coupon
      ret[:coupon_id] = self.coupon_id.to_s
      ret[:meta] = self.meta
      return ret
    end

  end

end
