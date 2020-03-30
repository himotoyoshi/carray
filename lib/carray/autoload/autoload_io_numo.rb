class CArray
  autoload_method "to_numo", "carray/io/numo"
end

module Numo
  class NArray
    autoload_method "to_ca", "carray/io/numo"
  end
end
