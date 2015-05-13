require 'ipaddr'
require 'open3'
require 'aws-eni/errors'

module Aws
  module ENI
    class Interface

      # Class level thread-safe lock
      @lock = Mutex.new

      class << self
        include Enumerable

        attr_accessor :verbose

        # Array-like accessor to automatically instantiate our class
        def [](index)
          case index
          when Integer
            @lock.synchronize do
              @instance_cache ||= []
              @instance_cache[index] ||= new("eth#{index}", false)
            end
          when nil
            self[next_available_index]
          when /^(?:eth)?([0-9]+)$/
            self[$1.to_i]
          when /^eni-/
            find { |dev| dev.interface_id == index }
          when /^[0-9a-f:]+$/i
            find { |dev| dev.hwaddr.casecmp(index) == 0 }
          when /^[0-9\.]+$/
            find { |dev| dev.has_ip?(index) }
          end.tap do |dev|
            raise Errors::UnknownInterface, "No interface found matching #{index}" unless dev
          end
        end

        # Purge and deconfigure non-existent interfaces from the cache
        def clean
          # exists? will automatically call deconfigure if necessary
          @instance_cache.map!{ |dev| dev if dev.exists? }
        end

        # Return the next unused device index
        def next_available_index
          for index in 0..32 do
            break index unless self[index].exists?
          end
        end

        # Iterate over available ethernet interfaces (required for Enumerable)
        def each(&block)
          Dir.entries("/sys/class/net/").grep(/^eth[0-9]+$/){ |name| self[name] }.each(&block)
        end

        # Return array of enabled interfaces
        def enabled
          select(&:enabled?)
        end

        # Configure all available interfaces identified by an optional selector
        def configure(selector = nil, options = {})
          filter(selector).reduce(0) do |count, dev|
            count + dev.configure(options[:dry_run])
          end
        end

        # Remove configuration on available interfaces identified by an optional
        # selector
        def deconfigure(selector = nil)
          filter(selector).each(&:deconfigure)
          true
        end

        # Return an array of available interfaces identified by name, id,
        # hwaddr, or subnet id.
        def filter(filter = nil)
          case filter
          when nil
            to_a
          when /^eni-/, /^eth[0-9]+$/, /^[0-9a-f:]+$/i, /^[0-9\.]+$/
            [*self[filter]]
          when /^subnet-/
            select { |dev| dev.subnet_id == filter }
          end.tap do |devs|
            raise Errors::UnknownInterface, "No interface found matching #{filter}" if devs.nil? || devs.empty?
          end
        end

        # Test whether we have permission to run RTNETLINK commands
        def mutable?
          cmd('link set dev eth0') # innocuous command
          true
        rescue Errors::InterfacePermissionError
          false
        end

        # Execute an 'ip' command
        def cmd(command, options = {})
          errors = options[:errors]
          options[:errors] = true
          begin
            exec("/sbin/ip #{command}", options)
          rescue Errors::InterfaceOperationError => e
            case e.message
            when /operation not permitted/i
              raise Errors::InterfacePermissionError, "Operation not permitted"
            else
              raise if errors
            end
          end
        end

        # Test connectivity from a given ip address
        def test(ip, options = {})
          timeout = Integer(options[:timeout] || 30)
          target = options[:target] || '8.8.8.8'
          !!exec("ping -w #{timeout} -c 1 -I #{ip} #{target}")
        end

        # Execute a command, returns output as string or nil on error
        def exec(command, options = {})
          output = nil
          errors = options[:errors]
          verbose = self.verbose || options[:verbose]

          puts command if verbose
          Open3.popen3(command) do |i,o,e,t|
            if t.value.success?
              output = o.read
            else
              error = e.read
              warn "Warning: #{error}" if verbose
              raise Errors::InterfaceOperationError, error if errors
            end
          end
          output
        end
      end

      attr_reader :name, :device_number, :route_table

      def initialize(name, auto_config = true)
        unless name =~ /^eth([0-9]+)$/
          raise Errors::InvalidInterface, "Invalid interface: #{name}"
        end
        @name = name
        @device_number = $1.to_i
        @route_table = @device_number + 10000
        @lock = Mutex.new
        configure if auto_config
      end

      # Get our interface's MAC address
      def hwaddr
        begin
          exists? && IO.read("/sys/class/net/#{name}/address").strip
        rescue Errno::ENOENT
        end.tap do |address|
          raise Errors::UnknownInterface, "Interface #{name} not found on this machine" unless address
        end
      end

      # Verify device exists on our system
      def exists?
        File.directory?("/sys/class/net/#{name}").tap do |exists|
          deconfigure unless exists || @clean
        end
      end

      # Validate and return basic interface metadata
      def info
        @lock.synchronize do
          hwaddr = self.hwaddr
          unless @meta_cache && @meta_cache[:hwaddr] == hwaddr
            @meta_cache = Meta.connection do
              raise Errors::MetaBadResponse unless Meta.interface(hwaddr, '', not_found: nil)
              {
                hwaddr:       hwaddr,
                interface_id: Meta.interface(hwaddr, 'interface-id'),
                subnet_id:    Meta.interface(hwaddr, 'subnet-id'),
                subnet_cidr:  Meta.interface(hwaddr, 'subnet-ipv4-cidr-block')
              }.freeze
            end
          end
          @meta_cache
        end
      rescue Errors::MetaConnectionFailed
        raise Errors::InvalidInterface, "Interface #{name} could not be found in the EC2 instance meta-data"
      end

      def interface_id
        info[:interface_id]
      end

      def subnet_id
        info[:subnet_id]
      end

      def subnet_cidr
        info[:subnet_cidr]
      end

      def gateway
        IPAddr.new(subnet_cidr).succ.to_s
      end

      def prefix
        subnet_cidr.split('/').last.to_i
      end

      # Return an array of configured ip addresses (primary + secondary)
      def local_ips
        list = cmd("addr show dev #{name} primary") +
               cmd("addr show dev #{name} secondary")
        list.lines.grep(/inet ([0-9\.]+)\/.* #{name}/i){ $1 }
      end

      # Return an array of ip addresses found in our instance metadata
      def meta_ips
        # hack to use cached hwaddr when available since this is often polled
        # continuously for changes
        hwaddr = (@meta_cache && @meta_cache[:hwaddr]) || hwaddr
        Meta.interface(hwaddr, 'local-ipv4s', cache: false).lines.map(&:strip)
      end

      # Return a hash of local/public ip associations found in instance metadata
      def public_ips
        hwaddr = self.hwaddr
        Hash[
          Meta.connection do
            Meta.interface(hwaddr, 'ipv4-associations/', not_found: '', cache: false).lines.map do |public_ip|
              public_ip.strip!
              [ Meta.interface(hwaddr, "ipv4-associations/#{public_ip}", cache: false), public_ip ]
            end
          end
        ]
      end

      # Enable our interface and create necessary routes
      def enable
        cmd("link set dev #{name} up")
        cmd("route add default via #{gateway} dev #{name} table #{route_table}")
        cmd("route flush cache")
      end

      # Disable our interface
      def disable
        cmd("link set dev #{name} down")
      end

      # Check whether our interface is enabled
      def enabled?
        exists? && cmd("link show up").include?(name)
      end

      # Initialize a new interface config
      def configure(dry_run = false)
        changes = 0
        prefix = self.prefix # prevent exists? check on each use

        local_primary, *local_aliases = local_ips
        meta_primary, *meta_aliases = meta_ips

        # ensure primary ip address is correct
        if name != 'eth0' && local_primary != meta_primary
          unless dry_run
            deconfigure
            cmd("addr add #{meta_primary}/#{prefix} brd + dev #{name}")
          end
          changes += 1
        end

        # add missing secondary ips
        (meta_aliases - local_aliases).each do |ip|
          cmd("addr add #{ip}/#{prefix} brd + dev #{name}") unless dry_run
          changes += 1
        end

        # remove extra secondary ips
        (local_aliases - meta_aliases).each do |ip|
          cmd("addr del #{ip}/#{prefix} dev #{name}") unless dry_run
          changes += 1
        end

        # add and remove source-ip based rules
        unless name == 'eth0'
          rules_to_add = meta_ips || []
          cmd("rule list").lines.grep(/^([0-9]+):.*\s([0-9\.]+)\s+lookup #{route_table}/) do
            unless rules_to_add.delete($2)
              cmd("rule delete pref #{$1}") unless dry_run
              changes += 1
            end
          end
          rules_to_add.each do |ip|
            cmd("rule add from #{ip} lookup #{route_table}") unless dry_run
            changes += 1
          end
        end

        @clean = nil
        changes
      end

      # Remove configuration for an interface
      def deconfigure
        # assume eth0 primary ip is managed by dhcp
        if name == 'eth0'
          cmd("addr flush dev eth0 secondary")
        else
          cmd("rule list").lines.grep(/^([0-9]+):.*lookup #{route_table}/) do
            cmd("rule delete pref #{$1}")
          end
          cmd("addr flush dev #{name}")
          cmd("route flush table #{route_table}")
          cmd("route flush cache")
        end
        @clean = true
      end

      # Add a secondary ip to this interface
      def add_alias(ip)
        cmd("addr add #{ip}/#{prefix} brd + dev #{name}")
        unless name == 'eth0' || cmd("rule list").include?("from #{ip} lookup #{route_table}")
          cmd("rule add from #{ip} lookup #{route_table}")
        end
      end

      # Remove a secondary ip from this interface
      def remove_alias(ip)
        cmd("addr del #{ip}/#{prefix} dev #{name}")
        unless name == 'eth0' || !cmd("rule list").match(/([0-9]+):\s+from #{ip} lookup #{route_table}/)
          cmd("rule delete pref #{$1}")
        end
      end

      # Return true if the ip address is associated with this interface
      def has_ip?(ip_addr)
        if IPAddr.new(subnet_cidr) === IPAddr.new(ip_addr)
          # ip within subnet
          local_ips.include? ip_addr
        else
          # ip outside subnet
          public_ips.has_value? ip_addr
        end
      end

      # Throw exception unless this interface matches the provided attributes
      # else returns self
      def assert(attr)
        error = nil
        attr.find do |attr,val|
          next if val.nil?
          error = case attr
            when :exists
              if val
                "The specified interface does not exist." unless exists?
              else
                "Interface #{name} exists." if exists?
              end
            when :enabled
              if val
                "Interface #{name} is not enabled." unless enabled?
              else
                "Interface #{name} is not disabled." if enabled?
              end
            when :name, :device_name
              "The specified interface does not match" unless name == val
            when :index, :device_index, :device_number
              "Interface #{name} is device number #{val}" unless device_number == val.to_i
            when :hwaddr
              "Interface #{name} does not match hwaddr #{val}" unless hwaddr == val
            when :interface_id
              "Interface #{name} does not have interface id #{val}" unless interface_id == val
            when :subnet_id
              "Interface #{name} does not have subnet id #{val}" unless subnet_id == val
            when :ip, :has_ip
              "Interface #{name} does not have IP #{val}" unless has_ip? val
            when :public_ip
              "Interface #{name} does not have public IP #{val}" unless public_ips.has_value? val
            when :local_ip, :private_ip
              "Interface #{name} does not have private IP #{val}" unless local_ips.include? val
            else
              "Unknown attribute: #{attr}"
            end
        end
        raise Errors::UnknownInterface, error if error
        self
      end

      # Return an array representation of our interface config, including public
      # ip associations and enabled status
      def to_h
        info.merge(
          name:          name,
          device_number: device_number,
          route_table:   route_table,
          local_ips:     local_ips,
          public_ips:    public_ips,
          enabled:       enabled?
        )
      end

      private

      # Alias for static method
      def cmd(*args) self.class.cmd(*args) end
    end
  end
end
