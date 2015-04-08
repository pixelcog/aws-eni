# aws-eni

A command line tool and client library to manage AWS Elastic Network Interfaces from within an EC2 instance.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'aws-eni'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install aws-eni

## Usage

Synchronize your EC2 instance network interface config with AWS.

    $ aws-eni sync

List all interface cards, their IPs, and their associations

    $ aws-eni list
    eth0:
      10.0.1.23
    eth1:
      10.0.2.54 => 54.25.169.87 (EIP)
      10.0.2.72 => 52.82.17.251 (EIP)

Add a new private IP

    $ aws-eni add eth1
    added 10.0.2.81

Associate a new elastic IP

    $ aws-eni associate 10.0.2.81
    associated 10.0.2.81 => 52.171.254.36

Dissociate an elastic IP

    $ aws-eni dissociate 10.0.2.81
    dissociated 52.171.254.36 from 10.0.2.81

Remove a private IP

    $ aws-eni remove 10.0.2.81
    removed 10.0.2.81 from eth1


## Contributing

1. Fork it ( https://github.com/[my-github-username]/aws-eni/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
