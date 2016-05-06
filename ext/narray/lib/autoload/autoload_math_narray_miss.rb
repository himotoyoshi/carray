
class CArray
  nam_rb = "carray/math/narray_miss"
  autoload_method :to_nam, nam_rb
  autoload_method :to_nam!, nam_rb
end

class NArrayMiss
  nam_rb = "carray/math/narray_miss"  
  autoload_method :to_ca, nam_rb
end