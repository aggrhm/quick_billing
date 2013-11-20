require "quick_billing/version"
require "quick_billing/accountable"
require "quick_billing/billing_plan"
require "quick_billing/transaction"

require "braintree"

module QuickBilling
  # Your code goes here...

  PAYMENT_PLATFORMS = {paypal: 1, braintree: 2}
  ACCOUNT_TYPES = {credit_card: 1}

  ## CONFIGURATION

  if defined?(Rails)
    # load configuration
    class Railtie < Rails::Railtie
      initializer "quick_billing.configure" do
        config_file = Rails.root.join("config", "quick_billing.yml")
        QuickNotify.configure(YAML.load_file(config_file)[Rails.env]) if File.exists?(config_file)
      end
    end
  end

  def self.configure(opts)
    @options = opts.with_indifferent_access unless opts.nil?
  end

  def self.options
    @options ||= {}
  end

  def self.platform
    case self.options[:platform]
    when :braintree
      Platforms::BrainTree
    end
  end

  ## CLASSES

  class PaymentMethod

    attr_accessor :type, :token, :number, :exp, :card_type

    def self.from_braintree_credit_card(card)
      pm = PaymentMethod.new(
        type: QuickBilling::ACCOUNT_TYPES[:credit_card],
        token: card.token,
        number: card.masked_number,
        exp: card.expiration_date,
        card_type: card.card_type
      )
      return pm
    end

    def initialize(opts={})
      opts.each do |key, val|
        self.send("#{key}=", val) if self.respond_to? key
      end
    end


    def to_api
      {
        type: self.type,
        token: self.token,
        number: self.number,
        exp: self.exp,
        card_type: self.card_type
      }
    end

  end

end
