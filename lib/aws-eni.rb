#!/usr/bin/env ruby

require 'net/http'
require 'aws-sdk'
require 'json'
require 'yaml'
require 'pp'
require_relative "aws-eni/version"

URL = "http://169.254.169.254/latest/meta-data/"
Aws.config.update({
	region: 'eu-west-1',
	credentials: Aws::Credentials.new('akid', 'secret') })
ec2 = Aws::EC2::Client.new

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


				url = URI.parse("#{URL}")
				req = Net::HTTP.new(url.host, url.port)
				res = req.request_head(url.path)
			rescue
				return false
				abort "We are not running on EC2."
			else
				if Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{@macs_arr.first}/vpc-id/")).include? "xml"
					return false
					abort "We are not running within VPC."
				else
					# this internal model should retain a list of interfaces (their names and
					# their MAC addresses), private ip addresses, and any public ip address
					# associations.
					@datahash = Hash.new
					n = 0
					@device_number_arr.each { |eth_num|
						@datahash.merge!("eth#{eth_num}" => "#{@private_ip_arr[n]}") if @public_ip_arr[n].include? "xml";
						@datahash.merge!("eth#{eth_num}" => {"#{@private_ip_arr[n]}" => "#{@public_ip_arr[n]}"}) if not @public_ip_arr[n].include? "xml";
						n+=1 }
					File.open("data.json","w") do |f|
						f.write(JSON.pretty_generate(@datahash))
					end
					return true
				end
			end
		end

		# return our internal model of this instance's network configuration on AWS
		def list(refresh=false)
			self.refresh if !ready? or refresh

			# return a hash or object representation of the internal model
			n = 0
			@device_number_arr.each { |dev|
				print "eth#{dev}:\n";
				print "	#{@private_ip_arr[n]}";
				print " => #{@public_ip_arr[n]}" if not @public_ip_arr[n].include? "xml";
				print "\n"; n += 1 }
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


		# create network interface
		def create
			@subnet_id = Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{@macs_arr.first}/subnet-id"))
			resp = ec2.create_network_interface(subnet_id: "#{@subnet_id}")
			@network_interface_id = resp[:network_interface][:network_interface_id]
			puts "created interface with id #{@network_interface_id}"
		end

		# attach network interface
		def attach
			@instance_id = Net::HTTP.get(URI.parse("#{URL}instance-id"))
			n = 0; @new_macs_arr = Array.new
			@macs_arr.each {|mac| @new_macs_arr.push(Net::HTTP.get(URI.parse("#{URL}network/interfaces/macs/#{mac}/device-number")))}
			@device_number = @new_macs_arr.sort.last
			@device_index = @device_number.to_i + 1
			resp = ec2.attach_network_interface(
				network_interface_id: "#{@network_interface_id}",
				instance_id: "#{@instance_id}",
				device_index: "#{@device_index}",
			)
			resp = ec2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
			@eth_ip = resp[:network_interfaces][0][:private_ip_address]
			puts "attached eth#{@device_index} with private ip #{@eth_ip}"
		end

		# detach network interface
		def detach
			resp = ec2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
			@network_attachment_id = resp[:network_interfaces][0][:attachment][:attachment_id]
			resp = ec2.detach_network_interface(
				attachment_id: "#{@network_attachment_id}",
				force: true,
			)
			puts "detached eth#{@device_index} with private ip #{@eth_ip}"
		end

		# delete network interface
		def delete
			resp = ec2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
			until resp[:network_interfaces][0][:status] == "available"
				sleep 5
				resp = ec2.describe_network_interfaces(network_interface_ids: ["#{@network_interface_id}"])
			end
			resp = ec2.delete_network_interface(network_interface_id: "#{@network_interface_id}")
			puts "removed interface eth#{@device_index} with id #{@network_interface_id}"
		end

		# add new private ip using the AWS api and add it to our local ip config
		def add(private_ip=nil, interface='eth0')

			# use AWS api to add a private ip address to the given interface.
			# if unspecified, let AWS auto-assign the ip.

			# add the new ip to the local config with `ip addr add ...` and use
			# `ip rule ...` or `ip route ...` if necessary

			# throw named exception if the private ip limit is reached, if the ip
			# specified is already in use, or for any similar error

			# return the new ip
		end

		# associate a private ip with an elastic ip through the AWS api
		def assoc(private_ip, public_ip=nil)

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

			# if interface not provided, infer it from the private ip. if it is
			# provided check that it corresponds to our private ip or raise an
			# exception. this is merely a safeguard

			# if the private ip has an associated EIP, call dissoc and pass in the
			# provided release parameter

			# remove the private ip from the local machine's config and routing tables
			# before using the AWS api to remove the private ip from our ENI.

			# return true
		end



		list if ARGV.include? 'list'
		refresh if ARGV.include? 'refresh'

	end
end
