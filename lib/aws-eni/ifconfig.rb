require 'ipaddr'
require 'open3'
require 'aws-eni/errors'

module Aws
  module ENI
    class IFconfig

      class << self
        include Enumerable

        attr_accessor :verbose

        # Array-like accessor to automatically instantiate our class
        def [](index)
          index = $1.to_i if index.to_s =~ /^(?:eth)?([0-9]+)$/
          index ||= next_available_index
          @instance_cache ||= []
          @instance_cache[index] ||= new("eth#{index}", false)
        end

        # Purge and deconfigure non-existent interfaces from the cache
        def clean
          # exists? will automatically call deconfigure if necessary
          @instance_cache.map!{ |dev| dev if dev.exists? }
        end

        # Return array of available ethernet interfaces
        def existing
          Dir.entries("/sys/class/net/").grep(/^eth[0-9]+$/){ |name| self[name] }
        end

        # Return the next unused device index
        def next_available_index
          for index in 0..32 do
            break index unless self[index].exists?
          end
        end

        # Iterate over available ethernet interfaces (required for Enumerable)
        def each(&block)
          existing.each(&block)
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
        def filter(match = nil)
          return existing unless match
          select{ |dev| dev.is?(match) }.tap do |result|
            raise UnknownInterfaceError, "No interface found matching \"#{match}\"" if result.empty?
          end
        end

        # Test whether we have permission to run RTNETLINK commands
        def mutable?
          exec 'link set dev eth0' # random innocuous command
          true
        rescue PermissionError
          false
        end

        # Execute a command
        def exec(command, options = {})
          output = nil
          verbose = self.verbose || options[:verbose]
          raise_errors = options[:raise_errors]
          puts "ip #{command}" if verbose

          Open3.popen3("/sbin/ip #{command}") do |i,o,e,t|
            if t.value.success?
              output = o.read
            else
              error_msg = e.read
              if error_msg =~ /operation not permitted/i
                raise PermissionError, "Operation not permitted"
              end
              warn "Warning: #{error_msg}" if verbose
              raise CommandError, error_msg if raise_errors
            end
          end
          output
        end
      end

      attr_reader :name, :device_number, :route_table

      def initialize(name, auto_config = true)
        unless name =~ /^eth([0-9]+)$/
          raise UnknownInterfaceError, "Invalid interface: #{name}"
        end
        @name = name
        @device_number = $1.to_i
        @route_table = @device_number + 10000
        configure if auto_config
      end

      # Get our interface's MAC address
      def hwaddr
        begin
          exists? && IO.read("/sys/class/net/#{name}/address").strip
        rescue Errno::ENOENT
        end.tap do |address|
          raise UnknownInterfaceError, "Unknown interface: #{name}" unless address
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
        hwaddr = self.hwaddr
        unless @meta_cache && hwaddr == @meta_cache[:hwaddr]
          dev_path = "network/interfaces/macs/#{hwaddr}"
          Meta.open_connection do |conn|
            raise BadResponse unless Meta.http_get(conn, "#{dev_path}/")
            @meta_cache = {
              hwaddr: hwaddr,
              interface_id: Meta.http_get(conn, "#{dev_path}/interface-id"),
              subnet_id:    Meta.http_get(conn, "#{dev_path}/subnet-id"),
              subnet_cidr:  Meta.http_get(conn, "#{dev_path}/subnet-ipv4-cidr-block")
            }.freeze
          end
        end
        @meta_cache
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

      # Return an array of configured ip addresses (primary + secondary)
      def local_ips
        list = exec("addr show dev #{name} primary") +
               exec("addr show dev #{name} secondary")
        list.lines.grep(/inet ([0-9\.]+)\/.* #{name}/i){ $1 }
      end

      def public_ips
        ip_assoc = {}
        dev_path = "network/interfaces/macs/#{hwaddr}"
        Meta.open_connection do |conn|
          # return an array of configured ip addresses (primary + secondary)
          Meta.http_get(conn, "#{dev_path}/ipv4-associations/").to_s.each_line do |public_ip|
            public_ip.strip!
            local_ip = Meta.http_get(conn, "#{dev_path}/ipv4-associations/#{public_ip}")
            ip_assoc[local_ip] = public_ip
          end
        end
        ip_assoc
      end

      # Enable our interface
      def enable
        exec("link set dev #{name} up")
      end

      # Disable our interface
      def disable
        exec("link set dev #{name} down")
      end

      # Check whether our interface is enabled
      def enabled?
        exists? && exec("link show up").include?(name)
      end

      # Initialize a new interface config
      def configure(dry_run = false)
        changes = 0
        info = self.info
        prefix = info[:subnet_cidr].split('/').last.to_i
        gateway = IPAddr.new(info[:subnet_cidr]).succ.to_s

        meta_ips = Meta.get("network/interfaces/macs/#{info[:hwaddr]}/local-ipv4s").lines.map(&:strip)
        local_primary, *local_aliases = local_ips
        meta_primary, *meta_aliases = meta_ips

        # ensure primary ip address is correct
        if name != 'eth0' && local_primary != meta_primary
          unless dry_run
            deconfigure
            exec("addr add #{meta_primary}/#{prefix} brd + dev #{name}")
            exec("route add default via #{gateway} dev #{name} table #{route_table}")
            exec("route flush cache")
          end
          changes += 1
        end

        # add missing secondary ips
        (meta_aliases - local_aliases).each do |ip|
          exec("addr add #{ip}/#{prefix} brd + dev #{name}") unless dry_run
          changes += 1
        end

        # remove extra secondary ips
        (local_aliases - meta_aliases).each do |ip|
          exec("addr del #{ip}/#{prefix} dev #{name}") unless dry_run
          changes += 1
        end

        unless name == 'eth0'
          rules_to_add = meta_ips || []
          exec("rule list").lines.grep(/^([0-9]+):.*\s([0-9\.]+)\s+lookup #{route_table}/) do
            unless rules_to_add.delete($2)
              exec("rule delete pref #{$1}") unless dry_run
              changes += 1
            end
          end
          rules_to_add.each do |ip|
            exec("rule add from #{ip} lookup #{route_table}") unless dry_run
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
          exec("addr flush dev eth0 secondary")
        else
          exec("rule list").lines.grep(/^([0-9]+):.*lookup #{route_table}/) do
            exec("rule delete pref #{$1}")
          end
          exec("addr flush dev #{name}")
          exec("route flush table #{route_table}")
          exec("route flush cache")
        end
        @clean = true
      end

      # Add a secondary ip to this interface
      def add_alias(ip)
        prefix = info[:subnet_cidr].split('/').last.to_i
        exec("addr add #{ip}/#{prefix} brd + dev #{name}")

        unless name == 'eth0' || exec("rule list") =~ /from #{ip} lookup #{route_table}/
          exec("rule add from #{ip} lookup #{route_table}")
        end
      end

      # Remove a secondary ip from this interface
      def remove_alias
        prefix = info[:subnet_cidr].split('/').last.to_i
        exec("addr del #{ip}/#{prefix} dev #{name}")

        if name != 'eth0' && exec("rule list") =~ /([0-9]+):\s+from #{ip} lookup #{route_table}/
          exec("rule delete pref #{$1}")
        end
      end

      # Identify this interface by one of its attributes
      def is?(match)
        if match == name
          true
        else
          info = self.info
          match == info[:interface_id] || match == info[:hwaddr] || match == info[:subnet_id]
        end
      end

      # Return an array representation of our interface config, including public
      # ip associations and enabled status
      def to_h
        info.merge({
          name:          name,
          device_number: device_number,
          route_table:   route_table,
          local_ips:     local_ips,
          public_ips:    public_ips,
          enabled:       enabled?
        })
      end

      private

      # Alias for static method
      def exec(command, options = {})
        self.class.exec(command, options)
      end
    end
  end
end
