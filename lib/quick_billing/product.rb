module QuickBilling

  module Product

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      def quick_billing_product!
        include QuickScript::Eventable
        include QuickScript::Model

        if self.respond_to?(:field)
          field :name, type: String
          field :key, type: String
          field :price, type: Integer
          field :period_interval, type: Integer
          field :period_unit, type: String
          field :is_available, type: :boolean, default: true
          field :is_public, type: :boolean, default: true
          field :metrics, type: Hash, default: Hash.new

          timestamps!
        end

        scope :available, lambda {
          where(is_available: true)
        }
        scope :is_public, lambda {
          where(is_public: true)
        }
      end

      def add_product!(key, name, price)
        if self.with_key(key).count > 0
          raise "Product with key already created"
        end
        product = self.new
        product.key = key.to_s
        product.name = name
        product.price = price
        product.save
        return product
      end

      def with_key(key)
        self.find_with_key(key)
      end

      def find_with_key(key)
        self.where(key: key).first
      end

    end

    ## INSTANCE METHODS

    def period_length
      case self.period_unit
      when 'month'
        return self.period_interval.months
      when 'year'
        return self.period_interval.years
      else
        return nil
      end
    end

    def period_length_hash
      {interval: self.period_interval, unit: self.period_unit}
    end

    def has_period?
      !self.period.nil?
    end

    def to_api(opt=:full)
      ret = {}
      ret[:id] = self.id.to_s
      ret[:name] = self.name
      ret[:key] = self.key
      ret[:price] = self.price
      ret[:metrics] = self.metrics
      ret[:period_unit] = self.period_unit
      ret[:period_interval] = self.period_interval

      return ret
    end

  end

end
