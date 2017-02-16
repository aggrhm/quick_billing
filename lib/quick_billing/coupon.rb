module QuickBilling

  module Coupon

    STYLES = {invoice: 1, transaction: 2}
    STATES = {active: 1, inactive: 2}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_coupon!
        include QuickScript::Eventable
        include QuickScript::Model
        if self.respond_to?(:field)
          field :style, type: Integer
          field :title, type: String
          field :code, type: String
          field :state, type: Integer
          field :amount, type: Integer
          field :percent, type: Integer
          field :max_redemptions, type: Integer
          field :max_uses, type: Integer
          field :source, type: String
          field :meta, type: Hash, default: Hash.new
          timestamps!
        end

        scope :with_source, lambda {|src|
          where(source: src)
        }
        scope :active, lambda {
          where(state: 1)
        }

        enum_methods! :state, STATES
        enum_methods! :style, STYLES

        validate do
          self.errors.add(:style, "Style cannot be blank.") if self.style.blank?
          self.errors.add(:title, "Title cannot be blank.") if self.title.blank?
          self.errors.add(:code, "Code cannot be blank.") if self.code.blank?
          self.errors.add(:state, "State cannot be blank.") if self.state.blank?
          self.errors.add(:amount, "Amount and percent cannot be blank.") if amount.blank? && percent.blank?
          self.errors.add(:amount, "Amount must be less than 0.") if amount.present? && amount >= 0
          self.errors.add(:percent, "Percent must be less than 0.") if percent.present? && percent >= 0
        end
      end

      def generate_code(len=8)
        SecureRandom.urlsafe_base64((len + 2)).gsub(/[^a-zA-Z0-9]/, "0")[0..(len-1)]
      end


    end

    ## INSTANCE METHODS

    def update_as_action!(opts)
      new_record = self.new_record?
      if new_record
        self.style! :invoice
        self.state! :active
        self.style = opts[:style] if opts.key?(:style)
        self.max_uses = 1
        self.code = opts[:code] || self.class.generate_code
      end
      self.title = opts[:title].strip if opts[:title]
      self.source = opts[:source].to_s.strip.downcase if opts[:source]
      self.amount = opts[:amount].to_i if opts.key?(:amount)
      self.percent = opts[:percent] if opts.key?(:percent)
      self.max_redemptions = opts[:max_redemptions].to_i if opts.key?(:max_redemptions)
      self.max_uses = opts[:max_uses].to_i if opts.key?(:max_uses)
      self.meta.merge!(opts[:meta]) if opts[:meta].is_a?(Hash)

      success = self.save
      return {success: success, data: self, error: self.error_message, new_record: new_record}
    end

    # ACCESSORS

    def invoiceable?
      self.style?(:invoice)
    end

    def transactionable?
      self.style?(:transaction)
    end

    def redemptions
      if self.invoiceable?
        # return entries
        QuickBilling.Entry.invoiced.for_coupon(self.id)
      else
        # return transactions
        QuickBilling.Transaction.completed.for_coupon(self.id)
      end
    end

    def redeemable?
      self.max_redemptions.nil? || (self.times_redeemed < self.max_redemptions)
    end

    def redeemable_by_account?(aid)
      return false if !(self.state?(:active) && self.redeemable?)
      # check if any account entries
      return false if QuickBilling.Entry.for_coupon(self.id).where(context: 2).is_valid.for_account(aid).count > 0
      return true
    end

    def times_redeemed_by_account(aid)
      # check adjustments
      self.redemptions.for_account(aid).count
    end

    def times_redeemed
      self.redemptions.count
    end

    def to_api(opt=:default)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:title] = self.title
      ret[:style] = self.style
      ret[:source] = self.source
      ret[:code] = self.code
      ret[:state] = self.state
      ret[:amount] = self.amount
      ret[:percent] = self.percent
      ret[:max_uses] = self.max_uses
      ret[:created_at] = self.created_at.to_i
      return ret
    end

  end

end
