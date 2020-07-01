class CArray
  autoload_method :to_numo, "carray-numo-narray"
  autoload_method :numo, "carray-numo-narray"
  autoload_method "self.as_numo", "carray-numo-narray"
  autoload_method "self.as_numo!", "carray-numo-narray"
  autoload_method :as_numo, "carray-numo-narray"
  autoload_method :as_numo!, "carray-numo-narray"
end

module Numo
  class NArray
    autoload_method :to_ca, "carray-numo-narray"
    autoload_method :ca, "carray-numo-narray"
  end
end
