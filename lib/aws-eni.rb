require 'time'
require 'aws-eni/version'
require 'aws-eni/errors'
require 'aws-eni/meta'
require 'aws-eni/client'
require 'aws-eni/interface'

module Aws
  module ENI
    extend self

    # class level thread-safe lock
    @lock = Mutex.new

    def environment
      @lock.synchronize do
        @environment ||= Meta.connection do
          hwaddr = Meta.instance('network/interfaces/macs/').lines.first.strip.chomp('/')
          {
            instance_id:       Meta.instance('instance-id'),
            availability_zone: Meta.instance('placement/availability-zone'),
            region:            Meta.instance('placement/availability-zone').sub(/^(.*)[a-z]$/,'\1'),
            vpc_id:            Meta.interface(hwaddr, 'vpc-id'),
            vpc_cidr:          Meta.interface(hwaddr, 'vpc-ipv4-cidr-block')
          }.freeze
        end
      end
    rescue Errors::MetaNotFound
      raise Errors::EnvironmentError, 'Unable to detect VPC, library incompatible with EC2-Classic'
    rescue Errors::MetaConnectionFailed
      raise Errors::EnvironmentError, 'Unable to load EC2 meta-data'
    end

    def owner_tag(new_owner = nil)
      @owner_tag = new_owner.to_s if new_owner
      @owner_tag ||= 'aws-eni script'
    end

    def timeout(new_default = nil)
      @timeout = new_default.to_i if new_default
      @timeout ||= 120
    end

    def verbose(set_verbose = nil)
      unless set_verbose.nil?
        @verbose = !!set_verbose
        Interface.verbose = @verbose
      end
      @verbose
    end

    # return our internal model of this instance's network configuration on AWS
    def list(filter = nil)
      Interface.filter(filter).map(&:to_h) if environment
    end

    # sync local machine's network interface config with the EC2 meta-data
    # pass dry_run option to check whether configuration is out of sync without
    # modifying it
    def configure(filter = nil, options = {})
      Interface.configure(filter, options) if environment
    end

    # clear local machine's network interface config
    def deconfigure(filter = nil)
      Interface.deconfigure(filter) if environment
    end

    # enable one or more network interfaces
    def enable(filter = nil)
      Interface.filter(filter).select{ |dev| !dev.enabled? }.each(&:enable).count
    end

    # disable one or more network interfaces
    def disable(filter = nil)
      Interface.filter(filter).select{ |dev| dev.enabled? && dev.name != 'eth0' }.each(&:disable).count
    end

    # create network interface
    def create_interface(options = {})
      timestamp = Time.now.xmlschema
      params = {}
      params[:subnet_id] = options[:subnet_id] || Interface.first.subnet_id
      params[:private_ip_address] = options[:primary_ip] if options[:primary_ip]
      params[:groups] = [*options[:security_groups]] if options[:security_groups]
      params[:description] = "generated by #{owner_tag} from #{environment[:instance_id]} on #{timestamp}"

      interface = Client.create_network_interface(params)[:network_interface]
      wait_for 'the interface to be created', rescue: Errors::UnknownInterface do
        if Client.describe_interface(interface[:network_interface_id])
          Client.create_tags(resources: [interface[:network_interface_id]], tags: [
            { key: 'created by',   value: owner_tag },
            { key: 'created on',   value: timestamp },
            { key: 'created from', value: environment[:instance_id] }
          ])
        end
      end
      {
        interface_id: interface[:network_interface_id],
        subnet_id:    interface[:subnet_id],
        api_response: interface
      }
    end

    # attach network interface
    def attach_interface(interface_id, options = {})
      do_block = options[:block] != false
      do_enable = options[:enable] != false
      do_config = options[:configure] != false
      assert_interface_access if do_config || do_enable

      device = Interface[options[:device_number] || options[:name]].assert(exists: false)

      begin
        response = Client.attach_network_interface(
          network_interface_id: interface_id,
          instance_id: environment[:instance_id],
          device_index: device.device_number
        )
      rescue EC2::Errors::AttachmentLimitExceeded
        raise Errors::ClientOperationError, "Unable to attach #{interface_id} to #{device.name} (attachment limit exceeded)"
      end

      if do_block || do_config || do_enable
        wait_for 'the interface to attach', rescue: Errors::InvalidInterface do
          device.exists? && Client.interface_attached(device.interface_id)
        end
      end
      device.configure if do_config
      device.enable if do_enable
      {
        interface_id:  interface_id,
        device_name:   device.name,
        device_number: device.device_number,
        enabled:       do_enable,
        configured:    do_config,
        api_response:  response
      }
    end

    # detach network interface
    def detach_interface(selector, options = {})
      device = Interface[selector].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      interface = Client.describe_interface(device.interface_id)

      do_release = !!options[:release]
      created_by_us = interface.tag_set.any? { |tag| tag.key == 'created by' && tag.value == owner_tag }
      do_delete = options[:delete] != false && created_by_us
      do_block = options[:block] != false

      if device.name == 'eth0'
        raise Errors::InvalidInterface, 'For safety, interface eth0 cannot be detached.'
      end
      unless interface[:attachment] && interface[:attachment][:instance_id] == environment[:instance_id]
        raise Errors::InvalidInterface, "Interface #{interface_id} is not attached to this machine"
      end

      public_ips = []
      interface[:private_ip_addresses].each do |addr|
        if assoc = addr[:association]
          public_ips << {
            public_ip:     assoc[:public_ip],
            allocation_id: assoc[:allocation_id]
          }
          dissociate_elastic_ip(assoc[:allocation_id], release: true) if do_release
        end
      end

      device.disable
      device.deconfigure
      Client.detach_network_interface(
        attachment_id: interface[:attachment][:attachment_id],
        force: true
      )
      if do_block || do_delete
        wait_for 'the interface to detach', interval: 0.3 do
          !device.exists? && !Client.interface_attached(interface[:network_interface_id])
        end
      end
      Client.delete_network_interface(network_interface_id: interface[:network_interface_id]) if do_delete
      {
        interface_id:  interface[:network_interface_id],
        device_name:   device.name,
        device_number: device.device_number,
        created_by_us: created_by_us,
        deleted:       do_delete,
        released:      do_release,
        public_ips:    public_ips,
        api_response:  interface
      }
    end

    # delete unattached network interfaces
    def clean_interfaces(filter = nil, options = {})
      public_ips = []
      do_release = !!options[:release]
      safe_mode = options[:safe_mode] != false

      filters = [
        { name: 'vpc-id', values: [environment[:vpc_id]] },
        { name: 'status', values: ['available'] }
      ]
      if filter
        case filter
        when /^eni-/
          filters << { name: 'network-interface-id', values: [filter] }
        when /^subnet-/
          filters << { name: 'subnet-id', values: [filter] }
        when /^#{environment[:region]}[a-z]$/
          filters << { name: 'availability-zone', values: [filter] }
        else
          raise Errors::InvalidInput, "Unknown interface attribute: #{filter}"
        end
      end
      if safe_mode
        filters << { name: 'tag:created by', values: [owner_tag] }
      end

      descriptions = Client.describe_network_interfaces(filters: filters)
      interfaces = descriptions[:network_interfaces].select do |interface|
        created_recently = interface.tag_set.any? do |tag|
          begin
            tag.key == 'created on' && Time.now - Time.parse(tag.value) < 60
          rescue ArgumentError
          end
        end
        unless safe_mode && created_recently
          interface[:private_ip_addresses].each do |addr|
            if assoc = addr[:association]
              public_ips << {
                public_ip:     assoc[:public_ip],
                allocation_id: assoc[:allocation_id]
              }
              dissociate_elastic_ip(assoc[:allocation_id], release: true) if do_release
            end
          end
          Client.delete_network_interface(network_interface_id: interface[:network_interface_id])
          true
        end
      end
      {
        interfaces:   interfaces.map { |eni| eni[:network_interface_id] },
        public_ips:   public_ips,
        released:     do_release,
        api_response: interfaces
      }
    end

    # add new private ip using the AWS api and add it to our local ip config
    def assign_secondary_ip(id, options = {})
      device = Interface[id].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      interface_id = device.interface_id
      current_ips = Client.interface_private_ips(interface_id)
      do_config = options[:configure] != false
      do_block = options[:block] != false
      new_ip = options[:private_ip]

      if do_block && !device.enabled?
        raise Errors::InvalidParameter, "Interface #{device.name} is not enabled (cannot test connection)"
      end

      if new_ip
        if current_ips.include?(new_ip)
          raise Errors::ClientOperationError, "IP #{new_ip} already assigned to #{device.name}"
        end
        Client.assign_private_ip_addresses(
          network_interface_id: interface_id,
          private_ip_addresses: [new_ip],
          allow_reassignment: false
        )
      else
        Client.assign_private_ip_addresses(
          network_interface_id: interface_id,
          secondary_private_ip_address_count: 1,
          allow_reassignment: false
        )
        wait_for 'new private IP address to be assigned' do
          client_ips = Client.interface_private_ips(interface_id)
          new_ip = (client_ips - current_ips).first || (device.meta_ips - current_ips).first
        end
      end

      if do_config
        device.add_alias(new_ip)
        if do_block && !Interface.test(new_ip, target: device.gateway, timeout: timeout)
          raise Errors::TimeoutError, 'Timed out waiting for IP address to become active'
        end
      end

      if do_block
        # ensure new state has propagated to avoid race conditions
        wait_for 'new private IP address to appear in metadata' do
          device.meta_ips.include?(new_ip)
        end
        wait_for 'new private IP address to appear in EC2 resource' do
          Client.interface_private_ips(interface_id).include?(new_ip)
        end
      end
      {
        private_ip:    new_ip,
        interface_id:  interface_id,
        device_name:   device.name,
        device_number: device.device_number,
        interface_ips: current_ips << new_ip
      }
    end

    # remove a private ip using the AWS api and remove it from local config
    def unassign_secondary_ip(private_ip, options = {})
      do_release = !!options[:release]
      do_block = options[:block] != false

      find = options[:device_name] || options[:device_number] || options[:interface_id] || private_ip
      device = Interface[find].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )

      interface = Client.describe_interface(device.interface_id)

      unless addr_info = interface[:private_ip_addresses].find { |addr| addr[:private_ip_address] == private_ip }
        raise Errors::ClientOperationError, "IP #{private_ip} not found on #{device.name}"
      end
      if addr_info[:primary]
        raise Errors::ClientOperationError, 'The primary IP address of an interface cannot be unassigned'
      end

      if assoc = addr_info[:association]
        dissociate_elastic_ip(assoc[:allocation_id], release: do_release)
      end

      device.remove_alias(private_ip)
      Client.unassign_private_ip_addresses(
        network_interface_id: interface[:network_interface_id],
        private_ip_addresses: [private_ip]
      )

      if do_block
        # ensure new state has propagated to avoid race conditions
        wait_for 'private IP address to be removed from metadata' do
          !device.meta_ips.include?(private_ip)
        end
        wait_for 'private IP address to be removed from EC2 resource' do
          !Client.interface_private_ips(device.interface_id).include?(private_ip)
        end
      end
      {
        private_ip:     private_ip,
        device_name:    device.name,
        interface_id:   device.interface_id,
        public_ip:      assoc && assoc[:public_ip],
        allocation_id:  assoc && assoc[:allocation_id],
        association_id: assoc && assoc[:association_id],
        released:       assoc && do_release
      }
    end

    # validate a local area connection on a secondary ip address
    def test_secondary_ip(private_ip, options = {})
      timeout = options[:timeout] || self.timeout

      find = options[:device_name] || options[:device_number] || options[:interface_id] || private_ip
      device = Interface[find].assert(
        exists: true,
        enabled: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number],
        private_ip:    private_ip
      )
      Interface.test(private_ip, target: device.gateway, timeout: timeout)
    end

    # associate a private ip with an elastic ip through the AWS api
    def associate_elastic_ip(private_ip, options = {})
      raise Errors::MissingInput, 'You must specify a private IP address' unless private_ip
      do_alloc = !!options[:new]
      do_block = options[:block] != false

      find = options[:device_name] || options[:device_number] || options[:interface_id] || private_ip
      device = Interface[find].assert(
        exists: true,
        private_ip:    private_ip,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      options[:public_ip] ||= options[:allocation_id]

      if do_block && !device.enabled?
        raise Errors::InvalidParameter, "Interface #{device.name} is not enabled (cannot block)"
      end
      if public_ip = device.public_ips[private_ip]
        raise Errors::ClientOperationError, "IP #{private_ip} already has an associated EIP (#{public_ip})"
      end

      if options[:public_ip]
        eip = Client.describe_address(options[:public_ip])
        if options[:allocation_id] && eip[:allocation_id] != options[:allocation_id]
          raise Errors::InvalidAddress, "EIP #{eip[:public_ip]} (#{eip[:allocation_id]}) does not match #{options[:allocation_id]}"
        end
      elsif do_alloc || !eip = Client.available_addresses.first
        allocated = true
        eip = allocate_elastic_ip
      end

      resp = Client.associate_address(
        network_interface_id: device.interface_id,
        allocation_id:        eip[:allocation_id],
        private_ip_address:   private_ip,
        allow_reassociation:  false
      )

      if do_block
        # ensure new state has propagated to avoid race conditions
        wait_for 'public IP address to appear in metadata' do
          device.public_ips.has_value?(eip[:public_ip])
        end
        if !Interface.test(private_ip, timeout: timeout)
          raise Errors::TimeoutError, 'Timed out waiting for IP address to become active'
        end
      end
      {
        private_ip:     private_ip,
        device_name:    device.name,
        interface_id:   device.interface_id,
        allocated:      !!allocated,
        public_ip:      eip[:public_ip],
        allocation_id:  eip[:allocation_id],
        association_id: resp[:association_id]
      }
    end

    # dissociate a public ip from a private ip through the AWS api and
    # optionally release the public ip
    def dissociate_elastic_ip(address, options = {})
      do_release = !!options[:release]
      do_block = options[:block] != false

      # assert device attributes if we've specified a device
      if find = options[:device_name] || options[:device_number]
        device = Interface[find].assert(
          device_name:   options[:device_name],
          device_number: options[:device_number],
          interface_id:  options[:interface_id],
          private_ip:    options[:private_ip],
          public_ip:     options[:public_ip]
        )
      end

      # get our address info
      eip = Client.describe_address(address)
      device ||= Interface.find { |dev| dev.interface_id == eip[:network_interface_id] }

      # assert eip attributes if options provided
      if options[:private_ip] && eip[:private_ip_address] != options[:private_ip]
        raise Errors::InvalidAddress, "#{address} is not associated with IP #{options[:private_ip]}"
      end
      if options[:public_ip] && eip[:public_ip] != options[:public_ip]
        raise Errors::InvalidAddress, "#{address} is not associated with public IP #{options[:public_ip]}"
      end
      if options[:allocation_id] && eip[:allocation_id] != options[:allocation_id]
        raise Errors::InvalidAddress, "#{address} is not associated with allocation ID #{options[:allocation_id]}"
      end
      if options[:association_id] && eip[:association_id] != options[:association_id]
        raise Errors::InvalidAddress, "#{address} is not associated with association ID #{options[:association_id]}"
      end
      if options[:interface_id] && eip[:network_interface_id] != options[:interface_id]
        raise Errors::InvalidAddress, "#{address} is not associated with interface ID #{options[:interface_id]}"
      end

      if device
        if device.name == 'eth0' && device.local_ips.first == eip[:private_ip_address]
          raise Errors::ClientOperationError, 'For safety, a public address cannot be dissociated from the primary IP on eth0'
        end
      elsif Client.interface_attached(eip[:network_interface_id])
        raise Errors::ClientOperationError, "#{address} is associated with an interface attached to another machine"
      end

      Client.disassociate_address(association_id: eip[:association_id])
      Client.release_address(allocation_id: eip[:allocation_id]) if do_release

      if device && do_block
        # ensure new state has propagated to avoid race conditions
        wait_for 'public IP address to be removed from metadata' do
          !device.public_ips.has_value?(eip[:public_ip])
        end
      end
      {
        private_ip:     eip[:private_ip_address],
        device_name:    device && device.name,
        interface_id:   eip[:network_interface_id],
        public_ip:      eip[:public_ip],
        allocation_id:  eip[:allocation_id],
        association_id: eip[:association_id],
        released:       do_release
      }
    end

    # validate an internet connection on a secondary ip address with an
    # associated elastic ip
    def test_association(address, options = {})
      timeout = options[:timeout] || self.timeout

      # assert device attributes if we've specified a device
      if find = options[:device_name] || options[:device_number]
        device = Interface[find].assert(
          device_name:   options[:device_name],
          device_number: options[:device_number],
          interface_id:  options[:interface_id],
          private_ip:    options[:private_ip],
          public_ip:     options[:public_ip]
        )
      end

      # get our address info
      eip = Client.describe_address(address)
      device ||= Interface.find { |dev| dev.interface_id == eip[:network_interface_id] }

      # assert eip attributes if options provided
      if options[:private_ip] && eip[:private_ip_address] != options[:private_ip]
        raise Errors::InvalidAddress, "#{address} is not associated with IP #{options[:private_ip]}"
      end
      if options[:public_ip] && eip[:public_ip] != options[:public_ip]
        raise Errors::InvalidAddress, "#{address} is not associated with public IP #{options[:public_ip]}"
      end
      if options[:allocation_id] && eip[:allocation_id] != options[:allocation_id]
        raise Errors::InvalidAddress, "#{address} is not associated with allocation ID #{options[:allocation_id]}"
      end
      if options[:association_id] && eip[:association_id] != options[:association_id]
        raise Errors::InvalidAddress, "#{address} is not associated with association ID #{options[:association_id]}"
      end
      if options[:interface_id] && eip[:network_interface_id] != options[:interface_id]
        raise Errors::InvalidAddress, "#{address} is not associated with interface ID #{options[:interface_id]}"
      end

      # assert that this eip attached to an enabled, configured interface on this machine
      unless device
        raise Errors::InvalidAddress, "#{address} is not associated with an interface on this machine"
      end
      unless device.enabled?
        raise Errors::InvalidAddress, "#{address} cannot be tested while #{device.name} is disabled"
      end
      unless device.local_ips.include?(eip[:private_ip_address])
        raise Errors::InvalidAddress, "#{address} cannot be tested until #{device.name} is configured"
      end

      Interface.test(eip[:private_ip_address], timeout: timeout)
    end

    # allocate a new elastic ip address
    def allocate_elastic_ip
      eip = Client.allocate_address(domain: 'vpc')
      wait_for 'new elastic ip to become available', rescue: Errors::UnknownAddress do
        # strangely this doesn't happen immediately in some cases
        Client.describe_address(eip[:allocation_id])
      end
      {
        public_ip:     eip[:public_ip],
        allocation_id: eip[:allocation_id]
      }
    end

    # release the specified elastic ip address
    def release_elastic_ip(ip)
      eip = Client.describe_address(ip)
      if eip[:association_id]
        raise Errors::ClientOperationError, "Elastic IP #{eip[:public_ip]} (#{eip[:allocation_id]}) is currently in use"
      end
      Client.release_address(allocation_id: eip[:allocation_id])
      {
        public_ip:     eip[:public_ip],
        allocation_id: eip[:allocation_id]
      }
    end

    # test whether we have permission to modify our machine's interface configuration
    def has_interface_access?
      Interface.mutable?
    end

    # throw exception if we cannot modify our machine's interface configuration
    def assert_interface_access
      raise Errors::InterfacePermissionError, 'Insufficient user priveleges to configure network interfaces' unless has_interface_access?
    end

    # test whether we have permission to perform all necessary EC2 operations
    # within our given AWS access credentials
    def has_client_access?
      Client.has_access?
    end

    # throw exception if we do not have permissions to perform all needed EC2
    # operations with our given AWS credentials
    def assert_client_access
      raise Errors::ClientPermissionError, 'Insufficient access to EC2 operations for network interface modification' unless has_client_access?
    end

    private

    def wait_for(task, options = {}, &block)
      errors = [*options[:rescue]]
      timeout = options[:timeout] || self.timeout
      interval = options[:interval] || 0.3

      until timeout < 0
        begin
          break if block.call
        rescue *errors => e
        end
        sleep interval
        timeout -= interval
      end
      raise Errors::TimeoutError, "Timed out waiting for #{task}" unless timeout > 0
    end
  end
end
