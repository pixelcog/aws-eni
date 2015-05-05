require 'aws-sdk'
require 'aws-eni/errors'
require 'aws-eni/meta'

module Aws
  module ENI
    module Client
      extend self

      # determine the region from instance metadata
      def region
        Meta.instance('placement/availability-zone').sub(/^(.*)[a-z]$/,'\1')
      rescue Errors::MetaConnectionFailed
        raise Errors::EnvironmentError, 'Unable to load EC2 meta-data'
      end

      # determine the vpc cidr block from instance metadata
      def vpc_cidr
        hwaddr = Meta.instance('network/interfaces/macs/').lines.first.strip.chomp('/')
        Meta.interface(hwaddr, 'vpc-ipv4-cidr-block')
      rescue Errors::MetaConnectionFailed, Errors::MetaNotFound
        raise Errors::EnvironmentError, 'Unable to load EC2 meta-data'
      end

      # lazy-load our ec2 client
      def client
        @client ||= EC2::Client.new(region: region)
      rescue StandardError => e
        raise Errors::EnvironmentError, 'Unable to initialize EC2 client'
      end

      # pass along method calls to our lazy-loaded api client
      def method_missing(method, *args)
        client.public_send(method, *args)
      rescue EC2::Errors::UnauthorizedOperation => e
        raise Errors::ClientPermissionError, "Operation not permitted: #{e.message}"
      rescue EC2::Errors::ServiceError => e
        error = e.class.to_s.gsub(/^.*::/, '')
        raise Errors::ClientOperationError, "EC2 service error (#{error}: #{e.message})"
      end

      # retrieve a single interface resource
      def describe_interface(id)
        resp = describe_network_interfaces(network_interface_ids: [id])
        raise Errors::UnknownInterface, "Interface #{id} could not be located" if resp[:network_interfaces].empty?
        resp[:network_interfaces].first
      end

      # retrieve a single address resource by public ip, associated private ip,
      # allocation id, or association id
      def describe_address(address)
        filter_by = case address
          when /^eipalloc-/
            'allocation-id'
          when /^eipassoc-/
            'association-id'
          else
            if IPAddr.new(vpc_cidr) === IPAddr.new(address)
              'private-ip-address'
            else
              'public-ip'
            end
          end
        resp = describe_addresses(filters: [
          { name: 'domain', values: ['vpc'] },
          { name: filter_by, values: [address] }
        ])
        raise Errors::UnknownAddress, "IP #{address} could not be located" if resp[:addresses].empty?
        resp[:addresses].first
      end

      # retrieve an array of private ips associated with the given interface
      def interface_private_ips(id)
        interface = describe_interface(id)
        if interface[:private_ip_addresses]
          primary = interface[:private_ip_addresses].find { |ip| ip[:primary] }
          interface[:private_ip_addresses].map { |ip| ip[:private_ip_address] }.tap do |ips|
            # ensure primary ip is first in the list
            ips.unshift(*ips.delete(primary[:private_ip_address])) if primary
          end
        end
      end

      # determine whether a given interface is attached or free
      def interface_attached(id)
        describe_interface(id)[:status] == 'in-use'
      end

      # test whether we have the appropriate permissions within our AWS access
      # credentials to perform all possible API calls
      def has_access?
        test_methods = {
          describe_network_interfaces: {},
          create_network_interface: {
            subnet_id: 'subnet-abcd1234'
          },
          attach_network_interface: {
            network_interface_id: 'eni-abcd1234',
            instance_id: 'i-abcd1234',
            device_index: 0
          },
          detach_network_interface: {
            attachment_id: 'eni-attach-abcd1234'
          },
          delete_network_interface: {
            network_interface_id: 'eni-abcd1234'
          },
          create_tags: {
            resources: ['eni-abcd1234'],
            tags: []
          },
          describe_addresses: {},
          allocate_address: {},
          release_address: {
            allocation_id: 'eipalloc-abcd1234'
          },
          associate_address: {
            allocation_id: 'eipalloc-abcd1234',
            network_interface_id: 'eni-abcd1234'
          },
          disassociate_address: {
            association_id: 'eipassoc-abcd1234'
          }
          # these have no dry_run method
          # assign_private_ip_addresses: {
          #   network_interface_id: 'eni-abcd1234'
          # }
          # unassign_private_ip_addresses: {
          #   network_interface_id: 'eni-abcd1234',
          #   private_ip_addresses: ['0.0.0.0']
          # }
        }
        test_methods.all? do |method, params|
          begin
            client.public_send(method, params.merge(dry_run: true))
          rescue EC2::Errors::DryRunOperation
            true
          rescue EC2::Errors::InvalidAllocationIDNotFound
            # release_address does not properly support dry_run
            true
          rescue EC2::Errors::UnauthorizedOperation
            false
          rescue
            raise Errors::ClientOperationError, 'Unexpected behavior while testing EC2 client permissions'
          else
            raise Errors::ClientOperationError, 'Unexpected behavior while testing EC2 client permissions'
          end
        end
      end
    end
  end
end
