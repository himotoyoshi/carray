class CArray
  class << self
    autoload_method :srand, "carray-random"
  end
  autoload_method :random!, "carray-random"
  autoload_method :shuffle, "carray-random"
  autoload_method :shuffle!, "carray-random"
end