# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'quick_billing/version'

Gem::Specification.new do |gem|
  gem.name          = "quick_billing"
  gem.version       = QuickBilling::VERSION
  gem.authors       = ["Alan Graham"]
  gem.email         = ["alan@productlab.com"]
  gem.description   = %q{A library for handling billing across multiple platforms (e.g. BrainTree Payments, Paypal)}
  gem.summary       = %q{A billing and payments management library for web APIs}
  gem.homepage      = ""

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency 'braintree', '2.36.0'
end
