module QuickBilling

  # This model represents a billable item pre-invoice. By specifying the invoices_limit and
  # invoices_left, we can use these to generate each invoice, knowing which Entries are
  # still invoiceable (recurring or once). Any parent model should determine which Entries
  # assigned to it are still invoiceable and create a new invoice with them, remembering to
  # decrement the invoices_left attribute.
  module Entry

    SOURCES = {discount: 1, tax: 2, prorate: 3, product: 4, general: 5}
    SOURCES_SORT_ORDER = [4, 5, 3, 1, 2]
    STATES = {valid: 1, voided: 2}
    CONTEXTS = {invoice: 1, account: 2, subscription: 3}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_entry!
        include QuickScript::Eventable
        include QuickScript::Model
        if self.respond_to?(:field)
          field :context, type: Integer
          field :source, type: Integer
          field :state, type: Integer, default: 1
          field :description, type: String
          field :amount, type: Integer
          field :percent, type: Integer
          field :cached_invoices_left, type: Integer, default: 0
          field :cached_invoices_count, type: Integer, default: 0    # invoice count
          field :invoices_limit, type: Integer, default: 1
          field :quantity, type: Integer, default: 1
          field :meta, type: Hash, default: {}

          field :subscription_id, type: Integer
          field :account_id, type: Integer
          field :coupon_id, type: Integer
          field :product_id, type: Integer
          field :invoice_id, type: Integer
          field :entry_id, type: Integer
          timestamps!

        end

        belongs_to :subscription, class_name: QuickBilling.classes[:subscription]
        belongs_to :account, class_name: QuickBilling.classes[:account]
        belongs_to :coupon, class_name: QuickBilling.classes[:coupon]
        belongs_to :product, class_name: QuickBilling.classes[:product]
        belongs_to :invoice, class_name: QuickBilling.classes[:invoice]
        belongs_to :entry, class_name: QuickBilling.classes[:entry]


        enum_methods! :source, SOURCES
        enum_methods! :state, STATES
        enum_methods! :context, CONTEXTS

        scope :for_coupon, lambda {|cid|
          where(coupon_id: cid)
        }
        scope :for_product, lambda {|pid|
          where(product_id: pid)
        }
        scope :for_account, lambda {|aid|
          where(account_id: aid)
        }
        scope :with_account_id, lambda {|aid|
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
          where("state = 1")
        }
        scope :with_source, lambda {|s|
          where(source: s)
        }
        scope :with_context, lambda {|c|
          where(context: c)
        }
        scope :invoiceable, lambda {
          is_valid.where("invoices_left is null OR invoices_left > 0")
        }
        scope :invoiced, lambda {
          includes(:invoice).where(context: 1, state: 1).where(invoices: {state: [2,3]})
        }

        validate do
          errors.add(:amount, "Must specify an amount or a percent.") if self.amount.nil? && self.percent.nil?
          errors.add(:quantity, "Quantity must be greater than 0.") if self.quantity <= 0
          errors.add(:context, "Entry context must be set.") if self.context.blank?
          errors.add(:description, "Entry description must be set.") if self.description.blank?
          errors.add(:state, "Entry state must be set.") if self.state.blank?
          errors.add(:source, "Entry source must be set.") if self.source.blank?
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

      def enter_coupon_for_account_as_action!(opts)
        success = false
        error = nil
        error_type = nil
        e = nil
        # find coupon
        coupon = QuickBilling.Coupon.find_by_code(opts[:coupon_code])
        if coupon.nil?
          error_type = "CouponNotFound"
          raise "Coupon could not be found."
        end
        # find account
        acct = QuickBilling.Account.find(opts[:account_id])
        if !coupon.redeemable_by_account?(acct.id)
          error_type = "CouponNotRedeemable"
          raise "This coupon is not redeemable by this account."
        end
        # determine if coupon can be redeemed by account
        e = self.new
        e.context! :account
        e.source! :discount
        e.state! :valid
        e.description = coupon.title
        e.amount = coupon.amount
        e.percent = coupon.percent
        e.invoices_limit = coupon.max_uses
        e.cached_invoices_left = coupon.max_uses
        e.account = acct
        e.coupon = coupon
        success = e.save
        if !success
          error = e.error_message
          error_type = "CouponNotSaved"
        end
      rescue => ex
        QuickScript.log_exception(ex)
        success = false
        error ||= ex.message
        error_type ||= "Error"
      ensure
        return {success: success, data: e, error: error, error_type: error_type, new_record: true}
      end

    end

    def update_as_action!(opts)
      new_record = self.new_record?
      if new_record
        self.state! :valid
        self.source! :general
        self.account = opts[:account] if opts.key?(:account)
        self.invoice = opts[:invoice] if opts.key?(:invoice)
        self.context = opts[:context] if opts.key?(:context)
        self.source = opts[:source] if opts.key?(:source)
        self.entry = opts[:entry] if opts.key?(:entry)
        self.coupon = opts[:coupon] if opts.key?(:coupon)
      end

      self.description = opts[:description] if opts.key?(:description)
      self.period_start = opts[:period_start] if opts.key?(:period_start)
      self.period_end = opts[:period_end] if opts.key?(:period_end)
      self.quantity = opts[:quantity].to_i if opts.key?(:quantity)
      self.amount = opts[:amount].to_i if opts.key?(:amount)
      self.percent = opts[:percent].to_i if opts.key?(:percent)
      self.meta.merge!(opts[:meta]) if opts.key?(:meta)

      success = self.save
      error = self.error_message

      return {success: success, data: self, error: error, new_record: new_record}
    end

    def usable?
      self.max_uses.nil? || (self.times_used < self.max_uses)
    end

    def invoiced?
      self.invoices_count > 0
    end

    def invoiceable?(reload=false)
      return false if self.state?(:voided)
      return true if self.invoices_limit.nil?
      return self.invoices_count < self.invoices_limit
    end

    def invoices_left
      check_invoices!
      return cached_invoices_left
    end

    def invoices_count
      check_invoices!
      return cached_invoices_count
    end

    def check_invoices!
      count = self.class.invoiced.where(entry_id: self.id).count
      self.cached_invoices_count = count
      self.cached_invoices_left = invoices_limit.present? ? invoices_limit - count : nil
      self.save(validate: false)
    end

    def add_to_invoice!(inv)
      e = self.class.new
      res = e.update_as_action!({
        account: self.account,
        coupon: self.coupon,
        invoice: inv,
        entry: self,
        source: self.source,
        context: CONTEXTS[:invoice],
        description: self.description,
        quantity: self.quantity,
        amount: self.amount,
        percent: self.percent
      })
      return res
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
      @total_amount = ret + self.amount * self.quantity
      return @total_amount
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
      ret[:description] = self.description
      ret[:source] = self.source
      ret[:amount] = self.amount
      ret[:percent] = self.percent
      ret[:quantity] = self.quantity
      ret[:product] = self.product.to_api if self.association(:product).loaded? && self.product
      ret[:product_id] = self.product_id.present? ? self.product_id.to_s : nil
      ret[:coupon] = self.coupon.to_api if self.association(:coupon).loaded? && self.coupon
      ret[:coupon_id] = self.coupon_id.present? ? self.coupon_id.to_s : nil
      ret[:invoices_left] = self.cached_invoices_left
      ret[:invoices_count] = self.cached_invoices_count
      ret[:total_amount] = @total_amount if !@total_amount.nil?
      ret[:meta] = self.meta
      return ret
    end

  end

end
