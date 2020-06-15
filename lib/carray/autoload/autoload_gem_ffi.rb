class CArray
  autoload_method "mp", "carray-ffi"
end

module FFI
  class MemoryPointer
    autoload_method "ca", "carray-ffi"     
  end
end
