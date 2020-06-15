class CArray
  autoload_method :na,    "carray-narray"
  autoload_method :to_na, "carray-narray"
end

class NArray
  autoload_method :ca,    "carray-narray"
  autoload_method :to_ca, "carray-narray"  
end

