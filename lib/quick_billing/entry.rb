module QuickBilling

  # This model represents a billable item pre-invoice. By specifying the invoice_limit and
  # invoices_left, we can use these to generate each invoice, knowing which Entries are
  # still invoiceable (recurring or once). Any parent model should determine which Entries
  # assigned to it are still invoiceable and create a new invoice with them, remembering to
  # decrement the invoices_left attribute.
  module Entry

    SOURCES = {discount: 1, tax: 2, prorate: 3, product: 4}
    SOURCES_SORT_ORDER = [4, 3, 1, 2]
    STATES = {valid: 1, voided: 2}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_entry_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model
          field :ds, as: :description, type: String
          field :st, as: :state, type: Integer, default: 1
          field :sr, as: :source, type: Integer
          field :am, as: :amount, type: Integer
          field :pr, as: :percent, type: Integer
          field :il, as: :invoices_left, type: Integer
          field :ic, type: Integer, default: 0    # invoice count
          field :im, as: :invoice_limit, type: Integer
          field :qn, as: :quantity, type: Integer, default: 1

          belongs_to :subscription, foreign_key: :sid, class_name: QuickBilling.Subscription.to_s
          belongs_to :account, foreign_key: :aid, class_name: QuickBilling.Account.to_s

          belongs_to :coupon, foreign_key: :cid, class_name: QuickBilling.Coupon.to_s
          belongs_to :product, foreign_key: :pid, class_name: QuickBilling.Product.to_s

          attr_alias :coupon_id, :cid
          attr_alias :product_id, :pid

          enum_methods! :source, SOURCES
          enum_methods! :state, STATES
        end

        scope :for_coupon, lambda {|cid|
          where(cid: cid)
        }
        scope :for_product, lambda {|pid|
          where(pid: pid)
        }
        scope :for_account, lambda {|aid|
          where(aid: aid)
        }
        scope :for_subscription, lambda {|sid|
          where(sid: sid)
        }
        scope :is_discount, lambda {
          where(sr: SOURCES[:discount])
        }
        scope :is_tax, lambda {
          where(sr: SOURCES[:tax])
        }
        scope :is_prorate, lambda {
          where(sr: SOURCES[:prorate])
        }
        scope :is_product, lambda {
          where(sr: SOURCES[:product])
        }
        scope :is_valid, lambda {
          where('st' => {'$ne' => 2})
        }
        scope :invoiceable, lambda {
          is_valid.where('$or' => [{il: nil}, {'il' => {'$exists' => false}}, {'il' => {'$gt' => 0}}])
        }
        scope :invoiced, lambda {
          where(:ic => {'$gt' => 0})
        }

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
        e.description = "Coupon"
        e.amount = coupon.amount
        e.percent = coupon.percent
        e.invoices_left = coupon.max_uses
        e.invoice_limit = coupon.max_uses
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
        return e
      end

    end

    def usable?
      self.max_uses.nil? || (self.times_used < self.max_uses)
    end

    def invoiced?
      self.invoice_count(true) > 0
    end

    def invoice_count(reload=false)
      if reload
        count = QuickBilling.Invoice.is_state(:charged).with_entry(self.id).count
        if !self.invoice_limit.nil?
          self.invoices_left = self.invoice_limit - count
        end
        self.ic = count
        self.save
      end
      self.ic
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

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s unless self.new_record?
      ret[:source] = self.source
      ret[:amount] = self.amount
      ret[:percent] = self.percent
      ret[:quantity] = self.quantity
      ret[:product] = self.product.to_api if self.product
      ret[:product_id] = self.product_id.to_s
      ret[:coupon] = self.coupon.to_api if self.coupon
      ret[:coupon_id] = self.coupon_id.to_s
      return ret
    end

  end

end
