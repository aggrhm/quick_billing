require "quick_billing/version"
require "quick_billing/billing_account"
require "quick_billing/billing_plan"
require "quick_billing/transaction"
require "quick_billing/subscription"
require "quick_billing/adapters/braintree_adapter"

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
        if File.exists?(config_file)
          QuickBilling.configure(YAML.load_file(config_file)[Rails.env])
        else
          QuickBilling.configure
        end
      end
    end
  end

  def self.configure(opts={})
    @options = opts.with_indifferent_access
    self.setup_classes

    case @options[:platform]
    when :braintree
      require 'braintree'
      self.setup_braintree
    end

    return @options
  end

  def self.setup_classes
    @options[:classes] ||= {}
    @options[:classes][:subscription] ||= ::Subscription
    @options[:classes][:billing_plan] ||= ::BillingPlan
    @options[:classes][:transaction] ||= ::Transaction
    @options[:classes][:billing_account] ||= ::BillingAccount
  end

  def self.setup_braintree
    Braintree::Configuration.environment = @options[:environment]
    Braintree::Configuration.merchant_id = @options[:merchant_id]
    Braintree::Configuration.public_key = @options[:merchant_public_key]
    Braintree::Configuration.private_key = @options[:merchant_private_key]
  end

  def self.options
    @options ||= {}
  end

  def self.platform
    case self.options[:platform]
    when :braintree
      Adapters::BraintreeAdapter
    end
  end

  def self.models
    self.options[:classes]
  end

  ## CLASSES

  class PaymentMethod

    attr_accessor :type, :token, :number, :expiration_date, :card_type

    def self.from_braintree_credit_card(card)
      pm = PaymentMethod.new(
        type: QuickBilling::ACCOUNT_TYPES[:credit_card],
        token: card.token,
        number: card.masked_number,
        expiration_date: card.expiration_date,
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
        expiration_date: self.expiration_date,
        card_type: self.card_type
      }
    end

  end

end
