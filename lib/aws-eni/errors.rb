
module Aws
  module ENI
    class Error < RuntimeError; end
    class MissingParameterError < Error; end
    class InvalidParameterError < Error; end
    class UnknownInterfaceError < Error; end
    class EnvironmentError < Error; end
    class CommandError < Error; end
    class PermissionError < CommandError; end
  end
end
