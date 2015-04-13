# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'aws-eni/version'

Gem::Specification.new do |spec|
  spec.name          = "aws-eni"
  spec.version       = AWS::ENI::VERSION
  spec.authors       = ["Mike Greiling"]
  spec.email         = ["mike@pixelcog.com"]
  spec.summary       = "Manage and sync local network config with AWS Elastic Network Interfaces"
  spec.description   = "A command line tool and client library to manage AWS Elastic Network Interfaces from within an EC2 instance"
  spec.homepage      = "http://pixelcog.com/"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"
end
