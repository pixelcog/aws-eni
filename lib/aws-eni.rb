require 'aws-sdk'
require 'aws-eni/errors'
require 'aws-eni/meta'
require 'aws-eni/ifconfig'

module Aws
  module ENI
    module_function

    def environment
      @environment ||= {}.tap do |e|
        hwaddr = IFconfig['eth0'].hwaddr
        Meta.open_connection do |conn|
          e[:instance_id] = Meta.http_get(conn, 'instance-id')
          e[:availability_zone] = Meta.http_get(conn, 'placement/availability-zone')
          e[:region] = e[:availability_zone].sub(/(.*)[a-z]/,'\1')
          e[:vpc_id] = Meta.http_get(conn, "network/interfaces/macs/#{hwaddr}/vpc-id")
        end
        unless e[:vpc_id]
          raise EnvironmentError, "Unable to detect VPC settings, library incompatible with EC2-Classic"
        end
      end.freeze
    rescue Meta::ConnectionFailed
      raise EnvironmentError, "Unable to load EC2 meta-data"
    end

    def client
      @client ||= Aws::EC2::Client.new(region: environment[:region])
    end

    # return our internal model of this instance's network configuration on AWS
    def list(filter = nil)
      IFconfig.filter(filter).map(&:to_h) if environment
    end

    # sync local machine's network interface config with the EC2 meta-data
    # pass dry_run option to check whether configuration is out of sync without
    # modifying it
    def configure(filter = nil, options = {})
      IFconfig.configure(filter, options) if environment
    end

    # clear local machine's network interface config
    def deconfigure(filter = nil)
      IFconfig.deconfigure(filter) if environment
    end

    # create network interface
    def create(refresh=false)
      self.refresh if refresh
      @subnet_id = Meta.get("network/interfaces/macs/#{@macs_arr.first}/subnet-id")
      resp = client.create_network_interface(subnet_id: "#{@subnet_id}")
      @network_interface_id = resp[:network_interface][:network_interface_id]
    end

    # attach network interface
    def attach(refresh=false)
      self.refresh if refresh
      @instance_id = Meta.get("instance-id")
      n = 0; @new_macs_arr = Array.new
      @macs_arr.each {|mac| @new_macs_arr.push(Meta.get("network/interfaces/macs/#{mac}/device-number"))}
      @device_number = @new_macs_arr.sort.last
      @device_index = @device_number.to_i + 1
      resp = client.attach_network_interface(
        network_interface_id: "#{@network_interface_id}",
        instance_id: "#{@instance_id}",
        device_index: "#{@device_index}",
      )
      resp = client.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      @private_ip = resp[:network_interfaces][0][:private_ip_address]
    end

    # detach network interface
    def detach(refresh=false)
      self.refresh if refresh
      resp = client.describe_network_interfaces(
        filters: [{
          name: "private-ip-address",
          values: ["#{@private_ip}"]
      }])
      @network_interface_id = resp[:network_interfaces][0][:network_interface_id]
      resp = client.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      @device_index = resp[:network_interfaces][0][:attachment][:device_index]
      @network_attachment_id = resp[:network_interfaces][0][:attachment][:attachment_id]
      resp = client.detach_network_interface(
        attachment_id: "#{@network_attachment_id}",
        force: true,
      )
      # puts "detached eth#{@device_index} with private ip #{@private_ip}"
    end

    # delete network interface
    def delete(refresh=false)
      self.refresh if refresh
      resp = client.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      until resp[:network_interfaces][0][:status] == "available"
        sleep 5
        resp = client.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
      end
      resp = client.delete_network_interface(network_interface_id: "#{@network_interface_id}")
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
      self.refresh if refresh

      # check that the private ip exists within our internal model and infer the
      # interface from that, throw exception otherwise
      @data_arr.each { |dev| @private_ip_exists = true if private_ip == dev['private_ip'] }
      raise Error, "Specified private ip does not exists" if @private_ip_exists == nil

      @private_ip = private_ip
      resp = client.describe_network_interfaces(
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
        resp = client.describe_addresses(
          public_ips: ["#{@public_ip}"],
          # allocation_ids: ["String", '...'],
        )

        raise Error, "IP does not exists" if resp['addresses'][0]['public_ip'] != @public_ip
        raise Error, "IP already associated with another interface" if resp['addresses'][0]['association_id'] != nil

        @allocation_id = resp['addresses'][0]['allocation_id']
        resp = client.associate_address(
          allocation_id: "#{@allocation_id}",
          network_interface_id: "#{@network_interface_id}",
          private_ip_address: "#{@private_ip}",
          allow_reassociation: true,
        )
      else
        resp = client.allocate_address(domain: "vpc")
        @public_ip = resp['public_ip']
        @allocation_id = resp['allocation_id']

        resp = client.associate_address(
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
