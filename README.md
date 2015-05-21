# aws-eni

A command line tool and ruby library to manage AWS Elastic Network Interfaces from within an EC2 instance.

## Notes

Your AWS access credentials will be introspected from either the environment variables or the EC2 instance meta-data (see AWS IAM instance role documentation).  Any command which requires a modification of the machine's interface configuration will require super-user privileges to access `/sbin/ip`.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'aws-eni'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install aws-eni

## Command Line Usage

Synchronize your EC2 instance network interface config with AWS.

    $ aws-eni config
    synchronized interface config

List all interface cards, their IPs, and their associations

    $ aws-eni list
    eth0:   ID eni-c02ef998  HWaddr 0e:96:b1:4a:15:2c  Status UP
            10.0.0.152 => 52.5.179.113
    eth1:   ID eni-585afa03  HWaddr 0e:90:7a:00:bf:7d  Status UP
            10.0.0.55

Add a secondary private IP

    $ aws-eni assign eth1
    IP 10.0.0.45 assigned to eth1 (eni-585afa03)

    $ aws-eni list eth1
    eth1:   ID eni-585afa03  HWaddr 0e:90:7a:00:bf:7d  Status UP
            10.0.0.55
            10.0.0.45

Associate a new Elastic IP

    $ aws-eni assoc 10.0.0.45
    EIP 52.5.141.210 (eipalloc-52117737) associated with 10.0.0.45 on eth1 (eni-585afa03)

    $ aws-eni list eth1
    eth1:   ID eni-585afa03  HWaddr 0e:90:7a:00:bf:7d  Status UP
            10.0.0.55
            10.0.0.45 => 52.5.141.210

Test a WAN connection through our newly associated Elastic IP

    $ aws-eni test 52.5.141.210
    EIP 52.5.141.210 connection successful

    $ curl --interface 10.0.0.45 ifconfig.me/ip
    52.5.141.210

Dissociate an elastic IP

    $ aws-eni dissoc 52.5.141.210
    EIP 52.5.141.210 (eipalloc-52117737) dissociated with 10.0.0.45 on eth1 (eni-585afa03)

    $ aws-eni list eth1
    eth1:   ID eni-585afa03  HWaddr 0e:90:7a:00:bf:7d  Status UP
            10.0.0.55
            10.0.0.45

Remove a secondary private IP

    $ aws-eni unassign 10.0.0.45
    IP 10.0.0.45 removed from eth1 (eni-585afa03)

    $ aws-eni list
    eth0:   ID eni-c02ef998  HWaddr 0e:96:b1:4a:15:2c  Status UP
            10.0.0.152 => 52.5.179.113
    eth1:   ID eni-585afa03  HWaddr 0e:90:7a:00:bf:7d  Status UP
            10.0.0.55

## Library Usage

```ruby
require 'aws-eni'

# create and attach a new interface
interface = Aws::ENI.create_interface
Aws::ENI.attach_interface(interface[:interface_id])

puts "Attached #{interface[:interface_id]} to #{interface[:device_name]}"

# add a secondary private IP to our new interface and associate an EIP
assign = Aws::ENI.assign_secondary_ip(interface[:device_name])
assoc = Aws::ENI.associate_elastic_ip(assign[:private_ip], block: false)

puts "Associated #{assoc[:public_ip]} with #{assoc[:private_ip]} on #{assoc[:device_name]}"

# verify our new public IP address (associate_elastic_ip normally does this
# automatically if 'block' option is not false)
if Aws::ENI.test_association(assoc[:public_ip])
  puts "#{assoc[:public_ip]} can successfully connect to the internet via #{assoc[:private_ip]}"
else
```

## AWS Policy

To use this utility, you will need to create and apply the following policy document.

Name it something like "AmazonEC2ElasticNetworkInterfaceAccess" and attach it to your IAM instance role or IAM user.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AllocateAddress",
                "ec2:AssignPrivateIpAddresses",
                "ec2:AssociateAddress",
                "ec2:AttachNetworkInterface",
                "ec2:CreateNetworkInterface",
                "ec2:CreateTags",
                "ec2:DeleteNetworkInterface",
                "ec2:DescribeAddresses",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DetachNetworkInterface",
                "ec2:DisassociateAddress",
                "ec2:ModifyNetworkInterfaceAttribute",
                "ec2:ReleaseAddress",
                "ec2:UnassignPrivateIpAddresses"
            ],
            "Resource": "*"
        }
    ]
}
```

## Contributing

1. Fork it ( https://github.com/pixelcog/aws-eni/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
