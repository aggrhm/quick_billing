module QuickBilling

  module Coupon

    STYLES = {subscription: 1, invoice: 1, account: 2}
    STATES = {active: 1, inactive: 2}

    def self.included(base)
      base.send :include, QuickBilling::ModelBase
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_coupon!
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

        enum_methods! :state, STATES
        enum_methods! :style, STYLES

        validate do
          self.errors.add(:style, "Style cannot be blank.") if self.style.blank?
          self.errors.add(:title, "Title cannot be blank.") if self.title.blank?
          self.errors.add(:code, "Code cannot be blank.") if self.code.blank?
          self.errors.add(:state, "State cannot be blank.") if self.state.blank?
        end
      end

      def find_with_code(code)
        where(code: code.strip).first || find(code)
      end

      def generate_code(len=8)
        SecureRandom.urlsafe_base64((len + 2)).gsub(/[^a-zA-Z0-9]/, "0")[0..(len-1)]
      end

    end

    ## INSTANCE METHODS

    def register!(opts)
      self.style!( (opts[:style] || :invoice) )
      self.title = opts[:title].strip if opts[:title]
      self.source = opts[:source].to_s.strip.downcase if opts[:source]
      self.amount = opts[:amount]
      self.percent = opts[:percent]
      self.max_redemptions = opts[:max_redemptions] ? opts[:max_redemptions].to_i : nil
      self.max_uses = opts[:max_uses] ? opts[:max_uses].to_i : 1
      self.meta.merge!(opts[:meta]) if opts[:meta].is_a?(Hash)

      self.code = opts[:code] || self.class.generate_code
      self.state! :active
      success = self.save
      return {success: success, data: self, error: self.error_message}
    end

    # ACCESSORS

    def invoiceable?
      self.style?(:invoice) || self.style?(:subscription)
    end

    def transactionable?
      self.style?(:account)
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
      if self.max_uses == nil
        return true
      else
        return self.times_redeemed_by_account(aid) < self.max_uses
      end
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
      return ret
    end

  end

end
