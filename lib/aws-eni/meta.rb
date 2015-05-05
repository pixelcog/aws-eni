require 'time'
require 'net/http'
require 'aws-eni/errors'

module Aws
  module ENI
    module Meta

      # These are the errors we trap when attempting to talk to the instance
      # metadata service.  Any of these imply the service is not present, not
      # responding or some other non-recoverable error.
      FAILURES = [
        Errno::EHOSTUNREACH,
        Errno::ECONNREFUSED,
        Errno::EHOSTDOWN,
        Errno::ENETUNREACH,
        Timeout::Error,
        SocketError,
        Errors::MetaBadResponse,
      ]

      # Perform a GET request on an open HTTP connection to the EC2 instance
      # meta-data and return the body of any 200 response.
      def self.get(path, options = {})
        @cache ||= {}
        if @cache[path] && options[:cache] != false
          @cache[path]
        else
          connection(options) do |http|
            response = http.request(Net::HTTP::Get.new(path))
            case response.code.to_i
            when 200
              @cache[path] = response.body
            when 404
              raise Errors::MetaNotFound unless options[:not_found]
              options[:not_found]
            else
              raise Errors::MetaBadResponse
            end
          end
        end
      end

      # Perform a GET request on the instance metadata and return the body of
      # any 200 response.
      def self.instance(path, options = {})
        get("/latest/meta-data/#{path}", options)
      end

      # Perform a GET request on the interface metadata and return the body of
      # any 200 response.
      def self.interface(hwaddr, path, options = {})
        instance("network/interfaces/macs/#{hwaddr}/#{path}", options)
      end

      # Open a connection and attempt to execute the block `retries` times.
      # Can specify open and read timeouts in addition to the number of retries.
      def self.connection(options = {})
        return yield(@open_connection) if @open_connection
        retries = options[:retries] || 5
        failed_attempts = 0
        begin
          http = Net::HTTP.new('169.254.169.254', '80', nil)
          http.open_timeout = options[:open_timeout] || 5
          http.read_timeout = options[:read_timeout] || 5
          @open_connection = http.start
          yield(http).tap { http.finish }
        rescue *FAILURES => e
          if failed_attempts < retries
            # retry after an ever increasing cooldown time with each failure
            Kernel.sleep(1.2 ** failed_attempts)
            failed_attempts += 1
            retry
          else
            raise Errors::MetaConnectionFailed, "EC2 Metadata request failed after #{retries} retries."
          end
        ensure
          @open_connection = nil
        end
      end
    end
  end
end
