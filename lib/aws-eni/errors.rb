
module Aws
  module ENI
    class Error < RuntimeError; end
    class TimeoutError < Error; end
    class MissingParameterError < Error; end
    class InvalidParameterError < Error; end
    class UnknownInterfaceError < Error; end
    class EnvironmentError < Error; end
    class CommandError < Error; end
    class PermissionError < CommandError; end
    class AWSPermissionError < Error; end
    class MetaBadResponse < Error; end
    class MetaConnectionFailed < Error; end
  end
end
