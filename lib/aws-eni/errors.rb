module Aws
  module ENI
    module Errors
      class ServiceError < RuntimeError; end

      class EnvironmentError < ServiceError; end

      class MetaNotFound < ServiceError; end
      class MetaBadResponse < ServiceError; end
      class MetaConnectionFailed < ServiceError; end

      class InterfaceOperationError < ServiceError; end
      class InterfacePermissionError < InterfaceOperationError; end

      class ClientOperationError < ServiceError; end
      class ClientPermissionError < ClientOperationError; end

      class MissingInput < ServiceError; end
      class InvalidInput < ServiceError; end
      class TimeoutError < ServiceError; end

      class UnknownInterface < ServiceError; end
      class InvalidInterface < ServiceError; end

      class UnknownAddress < ServiceError; end
      class InvalidAddress < ServiceError; end
    end
  end
end
