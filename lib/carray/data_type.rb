class CArray
  
  module DataTypeExtension
  end

  class Boolean
    extend DataTypeExtension
    TypeSymbol = :boolean
    TypeCode   = CA_BOOLEAN
  end

  class UInt8
    extend DataTypeExtension
    TypeSymbol = :uint8
    TypeCode   = CA_UINT8
  end

  class UInt16
    extend DataTypeExtension
    TypeSymbol = :uint16
    TypeCode   = CA_UINT16
  end

  class UInt32
    extend DataTypeExtension
    TypeSymbol = :uint32
    TypeCode   = CA_UINT32
  end

  class UInt64
    extend DataTypeExtension
    TypeSymbol = :uint64
    TypeCode   = CA_UINT64
  end

  class Int8
    extend DataTypeExtension
    TypeSymbol = :int8
    TypeCode   = CA_INT8
  end

  class Int16
    extend DataTypeExtension
    TypeSymbol = :int16
    TypeCode   = CA_INT16
  end

  class Int32
    extend DataTypeExtension
    TypeSymbol = :int32
    TypeCode   = CA_INT32
  end

  class Int64
    extend DataTypeExtension
    TypeSymbol = :int64
    TypeCode   = CA_INT64
  end

  class Float32
    extend DataTypeExtension
    TypeSymbol = :float32
    TypeCode   = CA_FLOAT32
  end

  SFloat = Float32

  class Float64
    extend DataTypeExtension
    TypeSymbol = :float64
    TypeCode   = CA_FLOAT64
  end

  DFloat = Float64

  class Complex64
    extend DataTypeExtension
    TypeSymbol = :complex64
    TypeCode   = CA_CMPLX64
  end

  SComplex = Complex64

  class Complex128
    extend DataTypeExtension
    TypeSymbol = :complex128
    TypeCode   = CA_CMPLX128
  end

  DComplex = Complex128

  class Object
    extend DataTypeExtension
    TypeSymbol = :object
    TypeCode   = CA_OBJECT
  end

  RObject = Object

  class Fixlen
    extend DataTypeExtension
    TypeSymbol = :fixlen
    TypeCode   = CA_FIXLEN
  end

end

class CArray
  extend DataTypeExtension
  TypeSymbol = nil
  TypeCode   = nil
end

class CArray
  
  module DataTypeExtension

    def guess_data_type_from_values (*values)
      if values.all? {|v| v == true || v == false }
        CA_BOOLEAN
      elsif values.all? { |v| v.is_a?(Integer) }
        CA_INT64
      elsif values.all? { |v| v.is_a?(Float) }
        CA_FLOAT64
      elsif values.all? { |v| v.is_a?(Complex) }
        CA_CMPLX128
      else
        CA_OBJECT
      end
    end
    
    private :guess_data_type_from_values

    def zeros (*shape)
      CArray.new(self::TypeCode || CA_FLOAT64, shape).zero
    end

    def ones (*shape)
      CArray.new(self::TypeCode || CA_FLOAT64 , shape).one
    end
    
    def eye (n, m = nil, k = 0)
      m ||= n
      mat = CArray.new(self::TypeCode || CA_FLOAT64, [n, m])
      start = k > 0 ? k : m - k - 1
      mat[[start..-1,m+1]] = 1
      mat
    end
    
    def identity (n)
      mat = CArray.new(self::TypeCode || CA_FLOAT64, [n, n])
      mat[[nil,n+1]] = 1
      mat      
    end
  
    def linspace (x1, x2, n = 100)
      data_type = self::TypeCode
      data_type ||= guess_data_type_from_values(x1, x2)
      CArray.new(data_type, [n]).span(x1..x2)
    end
  
    def arange (*args)
      case args.size
      when 3
        start, stop, step = *args
      when 2
        start, stop = *args
        step = 1
      when 1
        start = 0
        stop, = *args
        step = 1
      end
      data_type = self::TypeCode
      data_type ||= guess_data_type_from_values(start, stop, step)
      CArray.__new__(data_type, start..stop, step)
    end
  
    def full (shape, fill_value)
      data_type = self::TypeCode
      data_type ||= guess_data_type_from_values(fill_value)
      shape = [shape] unless shape.is_a?(Array)
      CArray.new(data_type, shape).fill(fill_value)
    end
  
  end
  
end