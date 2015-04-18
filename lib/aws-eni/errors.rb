
module Aws
  class ENI
    class Error < RuntimeError; end
    class UnknownInterfaceError < Error; end
    class EnvironmentError < Error; end
  end
end
