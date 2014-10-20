module QuickBilling

  module Adjustment

    SOURCES = {discount: 1, tax: 2, prorate: 3}

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_adjustment_keys_for(db)
        if db == :mongoid
          include MongoHelper::Model
          field :ds, as: :description, type: String
          field :sr, as: :source, type: Integer
          field :am, as: :amount, type: Integer
          field :pr, as: :percent, type: Integer
          field :tu, as: :times_used, type: Integer, default: 0
          field :mu, as: :max_uses, type: Integer
          field :cc, as: :coupon_code, type: String

          belongs_to :subscription, foreign_key: :sid, class_name: QuickBilling.Subscription.to_s
          belongs_to :account, foreign_key: :aid, class_name: QuickBilling.Account.to_s
          enum_methods! :source, SOURCES
        end

        scope :with_coupon_code, lambda {|code|
          where(cc: code)
        }
        scope :for_account, lambda {|aid|
          where(aid: aid)
        }
        scope :for_subscription, lambda {|sid|
          where(sid: sid)
        }
        scope :from_discount, lambda {
          where(sr: SOURCES[:discount])
        }
        scope :from_tax, lambda {
          where(sr: SOURCES[:tax])
        }
        scope :from_prorate, lambda {
          where(sr: SOURCES[:prorate])
        }

        validate do
          errors.add(:amount, "Must specify an amount or a percent") if self.amount.nil? && self.percent.nil?
        end

      end


    end

    def usable?
      self.max_uses.nil? || (self.times_used < self.max_uses)
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

  end

end
