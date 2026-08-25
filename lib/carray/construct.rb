#
# CA_INT8(data)
#   :
# CA_OBJECT(data)
#
# Cast +data+ to a CArray of the data_type indicated by the method name.
# This is a polymorphic cast (not a fresh allocator): the source +data+
# is coerced into a CArray of the target data_type, dispatching on its
# Ruby class. +data+ should be one of the following objects:
#
# * Numeric         -> CScalar (0-d CArray)
# * Array           -> shape-guessed CArray, element-wise cast
# * CArray          -> data_type cast (copy if same data_type, +to_type+ otherwise)
# * Range           -> arange-like sequence (start..stop with step 1)
# * String          -> parsed (per-data_type parser)
# * nil             -> empty CArray
# * any object responding to +to_ca+ or +to_a+ -> coerced then cast
#
# When the block returns a Numeric or CScalar object,
# the resulted array is a CScalar object.

# CA_BOOLEAN / CA_INT8 / ... / CA_OBJECT (+ type-name aliases CA_BYTE /
# CA_SHORT / CA_INT / CA_FLOAT / CA_DOUBLE / CA_COMPLEX / CA_DCOMPLEX /
# CA_SIZE) and CA_FIXLEN are defined as global functions in C
# (ext/carray_cast.c).

class CArray
  
  module DataTypeNewConstructor
  end
  
  module DataTypeExtension
  end

  # CArray whose elements are `boolean`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Boolean.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Boolean
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :boolean
    # @!visibility private
    DataType   = CA_BOOLEAN
  end

  # CArray whose elements are `uint8`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::UInt8.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class UInt8
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :uint8
    # @!visibility private
    DataType   = CA_UINT8
  end

  # CArray whose elements are `uint16`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::UInt16.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class UInt16
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :uint16
    # @!visibility private
    DataType   = CA_UINT16
  end

  # CArray whose elements are `uint32`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::UInt32.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class UInt32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :uint32
    # @!visibility private
    DataType   = CA_UINT32
  end

  # CArray whose elements are `uint64`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::UInt64.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class UInt64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :uint64
    # @!visibility private
    DataType   = CA_UINT64
  end

  # CArray whose elements are `int8`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Int8.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Int8
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :int8
    # @!visibility private
    DataType   = CA_INT8
  end

  # CArray whose elements are `int16`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Int16.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Int16
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :int16
    # @!visibility private
    DataType   = CA_INT16
  end

  # CArray whose elements are `int32`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Int32.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Int32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :int32
    # @!visibility private
    DataType   = CA_INT32
  end

  # CArray whose elements are `int64`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Int64.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Int64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :int64
    # @!visibility private
    DataType   = CA_INT64
  end

  # CArray whose elements are `float32`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Float32.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Float32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :float32
    # @!visibility private
    DataType   = CA_FLOAT32
  end

  # Numo-compatible alias of {Float32}.
  SFloat = Float32

  # CArray whose elements are `float64`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Float64.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Float64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :float64
    # @!visibility private
    DataType   = CA_FLOAT64
  end

  # Numo-compatible alias of {Float64}.
  DFloat = Float64

  # CArray whose elements are `complex64`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Complex64.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Complex64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :complex64
    # @!visibility private
    DataType   = CA_CMPLX64
  end

  # Numo-compatible alias of {Complex64}.
  SComplex = Complex64

  # CArray whose elements are `complex128`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Complex128.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Complex128
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :complex128
    # @!visibility private
    DataType   = CA_CMPLX128
  end

  # Numo-compatible alias of {Complex128}.
  DComplex = Complex128

  # CArray whose elements are `object`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Object.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Object
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :object
    # @!visibility private
    DataType   = CA_OBJECT
  end

  # Numo-compatible alias of {Object}.
  RObject = Object

  # CArray whose elements are `fixlen`.  Naming the element type as a
  # class lets a constructor be spelled `CArray::Fixlen.new(...)`; see
  # {DataTypeNewConstructor} for what that form adds.
  class Fixlen
    extend DataTypeNewConstructor
    extend DataTypeExtension
    # @!visibility private
    TypeSymbol = :fixlen
    # @!visibility private
    DataType   = CA_FIXLEN
  end

end

class CArray
  extend DataTypeExtension
  # @!visibility private
  TypeSymbol = nil
  # @!visibility private
  DataType   = nil
end

class CArray
  
  # Constructors added to every typed class ({Float64}, {Int32}, ...) so the
  # class itself names the element type.  Each forwards to the `CArray`
  # equivalent with `data_type:` filled in.
  module DataTypeNewConstructor

    # @overload new(*shape)
    #   Allocates a new CArray of this typed subclass with the given
    #   shape.
    #   @param shape [Array<Integer>] shape of the new CArray.
    #   @return [CArray]
    def new (*shape)
      CArray.new(self::DataType, shape)
    end

    # @overload from_memory_view(obj)
    #   Returns a fresh CArray interpreted as this typed subclass's
    #   `data_type`, imported by copy from a MemoryView producer.
    #   Forwards to
    #   `CArray.from_memory_view(obj, data_type: self::DataType)`; the
    #   result is always 1-D (chain `.reshape` for higher rank).
    #   @param obj [Object] MemoryView producer.
    #   @return [CArray]
    def from_memory_view (obj)
      CArray.from_memory_view(obj, data_type: self::DataType)
    end

    # @overload wrap_memory_view(obj)
    #   Returns a zero-copy CAWrap over `obj`'s MemoryView interpreted
    #   as this typed subclass's `data_type`. Forwards to
    #   `CArray.wrap_memory_view(obj, data_type: self::DataType)`; the
    #   result is always 1-D (chain `.reshape` for higher rank).
    #
    #   Here the receiver names the element type, not the class of the
    #   result: the call forwards with `CArray` as the receiver, so a
    #   `CAWrap` comes back. Choosing the class is the other reading of
    #   the receiver, and it lives on `CArray.wrap_memory_view` itself.
    #   @param obj [Object] MemoryView producer.
    #   @return [CAWrap]
    def wrap_memory_view (obj)
      CArray.wrap_memory_view(obj, data_type: self::DataType)
    end

  end
  
  # DataTypeExtension is the carrier module for Numo / NumPy-style
  # factory methods that are extended onto CArray and every typed
  # CArray::Int32 / Float64 / ... class below.  Its body is defined
  # in lib/carray/data_type_extension.rb (required after this file),
  # keeping the soft-compatibility surface separate from carray's
  # native constructor API.
  module DataTypeExtension
  end

end
