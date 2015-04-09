require "aws-eni/version"

module AWS
  module ENI
    extend self

    def ready?
      # return true if the internal model has been set (i.e. refresh has been
      # called at laest once)
    end

    # pull instance metadata, update internal model
    def refresh

      # when used as a simple command line utility, this internal model may seem
      # like overkill, but when used as a libray in a long-running process,
      # having a cached internal model will prevent the need to poll the
      # instance metadata on every method call.

      # this internal model should retain a list of interfaces (their names and
      # their MAC addresses), private ip addresses, and any public ip address
      # associations.

      # throw exception if we are not running on EC2 or if we are not running
      # within VPC
    end

    # return our internal model of this instance's network configuration on AWS
    def list(refresh: false)
      self.refresh if !ready? or refresh

      # return a hash or object representation of the internal model
    end

    # sync local machine's network interface config with the AWS config
    def sync(refresh: false)
      self.refresh if !ready? or refresh

      # use `ip addr ...` commands to list and validate the local network
      # interface config and compare it to our internal model, then add ips and
      # routing config such that the local config matches our model.
      # also ensure old ips and routes are excised from the config when they are
      # no longer in our model.

      # see http://engineering.silk.co/post/31923247961/multiple-ip-addresses-on-amazon-ec2
      # once configured, one should be able to run the following command for any
      # ip address with an associated public ip and not have the packets dropped
      # $ curl --interface ip.add.re.ss ifconfig.me

      # should be able to get by with only instance metadata and no AWS API
      # calls for this command

      # return the number of local entries which were updated (e.g. return 2 if
      # one private ip was added and another is removed from the local config)
    end

    ## Note:
    # all methods below will need to make use of the AWS api. credentials should
    # be optained through the environment variables: AWS_ACCESS_KEY_ID,
    # AWS_SECRET_ACCESS_KEY, etc. or via the "instance role" obtained through
    # the instance meta-data, same as the official aws command line tool. I do
    # not know if the official ruby AWS library has any sort of helper method
    # for obtaining these credentials or if this needs to be done manually.
    # if no instance role or environment variables detected, throw an exception

    # it may also be beneficial to maintain the associations between ENI device
    # name (i.e. eth0, eth1), ENI id within AWS (i.e. eni-e5aa89a3), and MAC
    # address (i.e. '0e:96:b6:4a:15:2c') within our internal model as we learn
    # them to make meta-data lookups and API calls easier.

    # add new private ip using the AWS api and add it to our local ip config
    def add(private_ip: nil, interface: 'eth0')

      # use AWS api to add a private ip address to the given interface.
      # if unspecified, let AWS auto-assign the ip.

      # add the new ip to the local config with `ip addr add ...` and use
      # `ip rule ...` or `ip route ...` if necessary

      # throw named exception if the private ip limit is reached, if the ip
      # specified is already in use, or for any similar error

      # return the new ip
    end

    # associate a private ip with an elastic ip through the AWS api
    def assoc(private_ip:, public_ip: nil)

      # check that the private ip exists within our internal model and infer the
      # interface from that, throw exception otherwise

      # if the public_ip parameter is specified use the AWS api to find an
      # existing "elastic ip" in this account and throw exception if it does not
      # exist or is otherwise unavailable (if already associated with another
      # instance or interface). if parameter not provided, create a new elastic
      # ip using the AWS api

      # associate this EIP with the provided private ip and the eni device we
      # inferred from it using the AWS api

      # return the public ip
    end

    # dissociate a public ip from a private ip through the AWS api and
    # optionally release the public ip
    def dissoc(private_ip: nil, public_ip: nil, release: true)

      # either private_ip or public_ip must be specified. if only one is
      # specified use internal model to infer the other. if not in our model,
      # throw an exception. if both are provided but are not associated in our
      # model, throw an exception.

      # use AWS api to dissociate the public ip from the private ip.
      # if release is truthy, remove the elastic ip after dissociating it.

      # return true
    end

    # remove a private ip using the AWS api and remove it from local config also
    def remove(private_ip:, interface: nil, release: true)

      # if interface not provided, infer it from the private ip. if it is
      # provided check that it corresponds to our private ip or raise an
      # exception. this is merely a safeguard

      # if the private ip has an associated EIP, call dissoc and pass in the
      # provided release parameter

      # remove the private ip from the local machine's config and routing tables
      # before using the AWS api to remove the private ip from our ENI.

      # return true
    end
  end
end
