#!/usr/bin/env ruby

require 'net/http'
require 'aws-sdk'
require 'json'
require 'pp'
require_relative "aws-eni/version"
require_relative "aws-eni/errors"

URL = "http://169.254.169.254/latest/meta-data/"
Aws.config.update({
  region: ENV['AWS_REGION'],
  credentials: Aws::SharedCredentials.new(:path => "#{ENV['HOME']}/.aws/config", :profile_name => "default") })
EC2 = Aws::EC2::Client.new

module AWS
  module ENI
    extend self

    def ready?
      # return true if the internal model has been set (i.e. refresh has been called at laest once)
      if @datahash != nil
      # if File.exist?("data.json")
        return true
      else
        return false
      end
    end

    # pull instance metadata, update internal model
    def refresh
      # throw exception if we are not running on EC2 or if we are not running within VPC
      begin
        @macs = Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/"))
        @macs_arr = Array.new
        @macs_arr = @macs.split(/\n/)

        @device_number_arr = Array.new
        @macs_arr.each { |mac| @device_number_arr.push(Net::HTTP.get(URI.parse(
          "#{URL}network/interfaces/macs/#{mac}/device-number"))) }

        @private_ip_arr = Array.new
        @macs_arr.each { |mac| @private_ip_arr.push(Net::HTTP.get(URI.parse(
          "#{URL}network/interfaces/macs/#{mac}/local-ipv4s"))) }

        @public_ip_arr = Array.new
        @macs_arr.each { |mac| @public_ip_arr.push(Net::HTTP.get(URI.parse(
          "#{URL}network/interfaces/macs/#{mac}/ipv4-associations/"))) }

        @instance_id = Net::HTTP.get(URI.parse("#{URL}instance-id"))


        url = URI.parse("#{URL}")
        req = Net::HTTP.new(url.host, url.port)
        res = req.request_head(url.path)
      rescue
        raise EnvironmentError, "We are not running on EC2"
      else
        if Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{@macs_arr.first}/vpc-id/")).include? "xml"
          raise EnvironmentError, "We are not running within VPC"
        else
          # this internal model should retain a list of interfaces (their names and
          # their MAC addresses), private ip addresses, and any public ip address
          # associations.
          @data_arr = Array.new
          n = 0
          @device_number_arr.each { |num|
            @datahash = Hash.new
            @datahash.merge!("device" => "eth#{num}")
            @datahash.merge!("mac" => "#{@macs_arr[n].gsub('/', '')}")
            @datahash.merge!("private_ip" => "#{@private_ip_arr[n]}")
            @datahash.merge!("public_ip" => "#{@public_ip_arr[n]}") if not @public_ip_arr[n].include? "xml"
            @data_arr << @datahash
            n+=1 }
          File.open("data.json","w") do |f|
            f.write(JSON.pretty_generate(@data_arr))
          end
          return true
        end
      end
    end

    # return our internal model of this instance's network configuration on AWS
    def list(refresh=false)
      self.refresh if !ready? or refresh

      # return a hash or object representation of the internal model
      return @data_arr
    end


    # sync local machine's network interface config with the AWS config
    def sync(refresh=false)
      self.refresh if !ready? or refresh
      sys_network = `ip ad sh`

      # use `ip addr ...` commands to list and validate the local network
      # interface config and compare it to our internal model, then add ips and
      # routing config such that the local config matches our model.
      # also ensure old ips and routes are excised from the config when they are
      # no longer in our model.

      # see http://engineering.silk.co/post/31923247961/multiple-ip-addresses-on-amazon-EC2
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


    # create network interface
    def create(refresh=false)
      self.refresh if !ready? or refresh
      @subnet_id = Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{@macs_arr.first}/subnet-id"))
      resp = EC2.create_network_interface(subnet_id: "#{@subnet_id}")
      @network_interface_id = resp[:network_interface][:network_interface_id]
    end

    # attach network interface
    def attach(refresh=false)
      self.refresh if !ready? or refresh
      @instance_id = Net::HTTP.get(URI.parse("#{URL}instance-id"))
      n = 0; @new_macs_arr = Array.new
      @macs_arr.each {|mac| @new_macs_arr.push(Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{mac}/device-number")))}
      @device_number = @new_macs_arr.sort.last
      @device_index = @device_number.to_i + 1
      resp = EC2.attach_network_interface(
        network_interface_id: "#{@network_interface_id}",
        instance_id: "#{@instance_id}",
        device_index: "#{@device_index}",
      )
      resp = EC2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      @private_ip = resp[:network_interfaces][0][:private_ip_address]
    end

    # detach network interface
    def detach(refresh=false)
      self.refresh if !ready? or refresh
      resp = EC2.describe_network_interfaces(
        filters: [{
          name: "private-ip-address",
          values: ["#{@private_ip}"]
      }])
      @network_interface_id = resp[:network_interfaces][0][:network_interface_id]
      resp = EC2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      @device_index = resp[:network_interfaces][0][:attachment][:device_index]
      @network_attachment_id = resp[:network_interfaces][0][:attachment][:attachment_id]
      resp = EC2.detach_network_interface(
        attachment_id: "#{@network_attachment_id}",
        force: true,
      )
      # puts "detached eth#{@device_index} with private ip #{@private_ip}"
    end

    # delete network interface
    def delete(refresh=false)
      self.refresh if !ready? or refresh
      resp = EC2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      until resp[:network_interfaces][0][:status] == "available"
        sleep 5
        resp = EC2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      end
      resp = EC2.delete_network_interface(network_interface_id: "#{@network_interface_id}")
      # puts "removed interface eth#{@device_index} with id #{@network_interface_id}"
    end

    # add new private ip using the AWS api and add it to our local ip config
    def add(private_ip=nil, interface='eth0')
      begin
        # use AWS api to add a private ip address to the given interface.
        # if unspecified, let AWS auto-assign the ip.
        self.create
        self.attach

        # add the new ip to the local config with `ip addr add ...` and use
        # `ip rule ...` or `ip route ...` if necessary

        sleep 3 while `ip ad sh dev eth#{@device_index} 2>&1`.include? 'does not exist'
        `sudo dhclient eth#{@device_index}`
        # `sudo ip ad add #{@private_ip} dev eth#{@device_index}`
        # `sudo ip link set dev eth#{@device_index} up`

        # throw named exception if the private ip limit is reached, if the ip
        # specified is already in use, or for any similar error
      rescue
        raise Error, "The private ip limit is reached"
      else
        if @private_ip == nil or @device_index == nil
          raise Error, "No data received from lib while adding interface"
        else
          # return the new ip and device
          return { "private_ip" => @private_ip, "device" => "eth#{@device_index}" }
        end
      end
    end

    # associate a private ip with an elastic ip through the AWS api
    def assoc(private_ip, public_ip=nil)
      self.refresh if !ready? or refresh

      # check that the private ip exists within our internal model and infer the
      # interface from that, throw exception otherwise
      @data_arr.each { |dev| @private_ip_exists = true if private_ip == dev['private_ip'] }
      raise Error, "Specified private ip does not exists" if @private_ip_exists == nil

      @private_ip = private_ip
      resp = EC2.describe_network_interfaces(
        filters: [{
          name: "private-ip-address",
          values: ["#{@private_ip}"]
      }])
      @network_interface_id = resp[:network_interfaces][0][:network_interface_id]

      # if the public_ip parameter is specified use the AWS api to find an
      # existing "elastic ip" in this account and throw exception if it does not
      # exist or is otherwise unavailable (if already associated with another
      # instance or interface). if parameter not provided, create a new elastic
      # ip using the AWS api

      # associate this EIP with the provided private ip and the eni device we
      # inferred from it using the AWS api

      if public_ip != nil
        @public_ip = public_ip
        resp = EC2.describe_addresses(
          public_ips: ["#{@public_ip}"],
          # allocation_ids: ["String", '...'],
        )

        raise Error, "IP does not exists" if resp['addresses'][0]['public_ip'] != @public_ip
        raise Error, "IP already associated with another interface" if resp['addresses'][0]['association_id'] != nil

        @allocation_id = resp['addresses'][0]['allocation_id']
        resp = EC2.associate_address(
          allocation_id: "#{@allocation_id}",
          network_interface_id: "#{@network_interface_id}",
          private_ip_address: "#{@private_ip}",
          allow_reassociation: true,
        )
      else
        resp = EC2.allocate_address(domain: "vpc")
        @public_ip = resp['public_ip']
        @allocation_id = resp['allocation_id']

        resp = EC2.associate_address(
          # instance_id: "#{@instance_id}",
          # public_ip: "#{@public_ip}",
          allocation_id: "#{@allocation_id}",
          network_interface_id: "#{@network_interface_id}",
          private_ip_address: "#{@private_ip}",
          allow_reassociation: true,
        )
        @association_id = resp['association_id']
      end

      # return the public ip
      return { "private_ip" => @private_ip, "public_ip" => @public_ip }
    end

    # dissociate a public ip from a private ip through the AWS api and
    # optionally release the public ip
    def dissoc(private_ip=nil, public_ip=nil, release=true)

      # either private_ip or public_ip must be specified. if only one is
      # specified use internal model to infer the other. if not in our model,
      # throw an exception. if both are provided but are not associated in our
      # model, throw an exception.

      # use AWS api to dissociate the public ip from the private ip.
      # if release is truthy, remove the elastic ip after dissociating it.

      # return true
    end

    # remove a private ip using the AWS api and remove it from local config also
    def remove(private_ip, interface=nil, release=true)
      begin
        @private_ip = private_ip
        self.detach
        self.delete
        # if interface not provided, infer it from the private ip. if it is
        # provided check that it corresponds to our private ip or raise an
        # exception. this is merely a safeguard

        # if the private ip has an associated EIP, call dissoc and pass in the
        # provided release parameter

        # remove the private ip from the local machine's config and routing tables
        # before using the AWS api to remove the private ip from our ENI.

      rescue
        raise Error, ""
      else
        if @private_ip == nil or @device_index == nil
          raise Error, "No data received from lib while adding interface"
        else
          return { "device" => "eth#{@device_index}", "private_ip" => @private_ip, "public_ip" => @public_ip, "release" => release }
        end
      end
    end

  end
end
