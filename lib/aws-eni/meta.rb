require 'time'
require 'net/http'

module Aws
  module ENI
    module Meta

      # EC2 instance meta-data connection settings
      HOST = '169.254.169.254'
      PORT = '80'
      BASE = '/latest/meta-data/'

      # Custom exception classes
      class BadResponse < RuntimeError; end
      class ConnectionFailed < RuntimeError; end

      # These are the errors we trap when attempting to talk to the instance
      # metadata service.  Any of these imply the service is not present, no
      # responding or some other non-recoverable error.
      FAILURES = [
        Errno::EHOSTUNREACH,
        Errno::ECONNREFUSED,
        Errno::EHOSTDOWN,
        Errno::ENETUNREACH,
        SocketError,
        Timeout::Error,
        BadResponse,
      ]

      # Open connection and run a single GET request on the instance metadata
      # endpoint. Same options as open_connection.
      def self.get(path, options = {})
        open_connection options do |conn|
          http_get(conn, path)
        end
      end

      # Open a connection and attempt to execute the block `retries` times.
      # Can specify open and read timeouts in addition to the number of retries.
      def self.open_connection(options = {})
        retries = options[:retries] || 5
        failed_attempts = 0
        begin
          http = Net::HTTP.new(HOST, PORT, nil)
          http.open_timeout = options[:open_timeout] || 5
          http.read_timeout = options[:read_timeout] || 5
          http.start
          yield(http).tap { http.finish }
        rescue *FAILURES => e
          if failed_attempts < retries
            # retry after an ever increasing cooldown time with each failure
            Kernel.sleep(1.2 ** failed_attempts)
            failed_attempts += 1
            retry
          else
            raise ConnectionFailed, "Connection failed after #{retries} retries."
          end
        end
      end

      # Perform a GET request on an open connection to the instance metadata
      # endpoint and return the body of any 200 response.
      def self.http_get(connection, path)
        response = connection.request(Net::HTTP::Get.new(BASE + path))
        case response.code.to_i
        when 200
          response.body
        when 404
          nil
        else
          raise BadResponse
        end
      end
    end
  end
end
