# ----------------------------------------------------------------------------
#
#  carray/constructor.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray
  
  #
  # CArray.span(data_type, range[, step])
  # CArray.span(range[, step]) -> data_type guessed by range.first type
  #

  def self.span (*argv)
    if argv.first.is_a?(Range)
      type = nil
    else
      type, = *CArray.guess_type_and_bytes(argv.shift, nil)
    end
    range, step = argv[0], argv[1]
    start, stop = range.begin, range.end
    if step == 0
      raise "step should not be 0"
    end
    if not type
      case start
      when Integer
        type = CA_INT32
      when Float
        type = CA_FLOAT64
      else
        type = CA_OBJECT
      end
    end
    if type == CA_OBJECT and not step
      return CA_OBJECT(range.to_a)
    else
      step ||= 1
      if range.exclude_end?
        n = ((stop - start).abs/step).floor
      else
        n = ((stop - start).abs/step).floor + 1
      end
      if start <= stop
        return CArray.new(type, [n]).seq(start, step)
      else
        return CArray.new(type, [n]).seq(start, -step.abs)
      end
    end
  end

  def span! (range)
    first = range.begin.to_r
    last  = range.end.to_r
    if integer?
      if range.exclude_end?
        step = ((last-1)-first+1)/elements
      else
        step = (last-first+1)/elements
      end      
    else
      if range.exclude_end?
        step = (last-first)/elements
      else
        step = (last-first)/(elements-1)
      end
    end
    if integer? && step.denominator != 1
      self[] = (first + seq * step).floor
    else
      seq!(first, step)
    end
    return self
  end

  def span (range)
    return template.span!(range)
  end

  #
  #
  #

  def scale! (xa, xb)
    xa = xa.to_f
    xb = xb.to_f
    seq!(xa, (xb-xa)/(elements-1))
  end

  def scale (xa, xb)
    template.scale!(xa, xb)
  end
  
  # @private 
  # Create new CArray object from the return value of the block
  # with data type +type+. The dimensional size and the initialization value
  # are guessed from the return value of the block.
  # The block should return one of the following objects.
  #
  # * Numeric
  # * Array
  # * CArray
  # * an object that has either method +to_ca+ or +to_a+ or +map+
  #
  # When the return value of the block is a Numeric or CScalar object,
  # CScalar object is returned.
  #
  def self.__new__ (type, *args) # :nodoc:
    case v = args.first
    when CArray
      return ( v.data_type == type ) ? v.to_ca : v.to_type(type)
    when Array
      return CArray.new(type, CArray.guess_array_shape(v)) { v }
    when Range
      return CArray.span(type, *args)
    when String
      if type == CA_OBJECT
        return CScalar.new(CA_OBJECT) { v }
      elsif type == CA_BOOLEAN
          v = v.dup
          v.tr!('^01',"1")
          v.tr!('01',"\x0\x1")
          return CArray.boolean(v.length).load_binary(v)
      else
        case v
        when /;/
          v = v.strip.split(/\s*;\s*/).
                           map{|s| s.split(/\s+|\s*,\s*/).map{|x| x=='_' ? UNDEF : x} }
        else
          v = v.strip.split(/\s+|\s*,\s*/).map{|x| x=='_' ? UNDEF : x}
        end
        return CArray.new(type, CArray.guess_array_shape(v)) { v }
      end
    when NilClass
      return CArray.new(type, [0])
    else
      if v.respond_to?(:to_ca)
        ca = v.to_ca
        return ( ca.data_type == type ) ? ca : ca.to_type(type)
      else
        return CScalar.new(type) { v }
      end
    end
  end

  # @private 
  def self.__new_fixlen__ (bytes, v) # :nodoc:
    case v
    when CArray
      return ( v.data_type == :fixlen ) ? v.to_ca : v.to_type(:fixlen, :bytes=>bytes)
    when Array
      unless bytes
        bytes = v.map{|s| s.length}.max
      end
      return CArray.new(:fixlen, CArray.guess_array_shape(v), :bytes=>bytes) { v }
    when NilClass
      return CArray.new(type, [0])
    else
      if v.respond_to?(:to_ca)
        ca = v.to_ca
        return ( ca.data_type == :fixlen ) ? ca : ca.to_type(:fixlen, :bytes=>bytes)
      else
        return CScalar.new(:fixlen, :bytes=>bytes) { v }
      end
    end
  end

end

#
# CA_INT8(data)
#   :
# CA_CMPLX256(data)
#
# Create new CArray object from +data+ with data type
# which is guessed from the method name. +data+ should be one of the following
# objects.
#
# * Numeric
# * Array
# * CArray
# * an object that has either method +to_ca+ or +to_a+ or +map+
#
# When the block returns a Numeric or CScalar object,
# the resulted array is a CScalar object.

[
 "CA_BOOLEAN",
 "CA_INT8",
 "CA_UINT8",
 "CA_INT16",
 "CA_UINT16",
 "CA_INT32",
 "CA_UINT32",
 "CA_INT64",
 "CA_UINT64",
 "CA_FLOAT32",
 "CA_FLOAT64",
 "CA_FLOAT128",
 "CA_CMPLX64",
 "CA_CMPLX128",
 "CA_CMPLX256",
 "CA_OBJECT",
 "CA_BYTE",
 "CA_SHORT",
 "CA_INT",
 "CA_FLOAT",
 "CA_DOUBLE",
 "CA_COMPLEX",
 "CA_DCOMPLEX",
 "CA_SIZE",
].each do |name|
  eval %{
    def #{name} (*val)
      CArray.__new__(#{name}, *val)
    end
  }
end

def CA_FIXLEN (val, options = {})
  CArray.__new_fixlen__(options[:bytes], val)
end

class CArray
  
  module DataTypeNewConstructor
  end
  
  module DataTypeExtension
  end

  class Boolean
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :boolean
    DataType   = CA_BOOLEAN
  end

  class UInt8
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :uint8
    DataType   = CA_UINT8
  end

  class UInt16
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :uint16
    DataType   = CA_UINT16
  end

  class UInt32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :uint32
    DataType   = CA_UINT32
  end

  class UInt64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :uint64
    DataType   = CA_UINT64
  end

  class Int8
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :int8
    DataType   = CA_INT8
  end

  class Int16
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :int16
    DataType   = CA_INT16
  end

  class Int32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :int32
    DataType   = CA_INT32
  end

  class Int64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :int64
    DataType   = CA_INT64
  end

  class Float32
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :float32
    DataType   = CA_FLOAT32
  end

  SFloat = Float32

  class Float64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :float64
    DataType   = CA_FLOAT64
  end

  DFloat = Float64

  class Complex64
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :complex64
    DataType   = CA_CMPLX64
  end

  SComplex = Complex64

  class Complex128
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :complex128
    DataType   = CA_CMPLX128
  end

  DComplex = Complex128

  class Object
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :object
    DataType   = CA_OBJECT
  end

  RObject = Object

  class Fixlen
    extend DataTypeNewConstructor
    extend DataTypeExtension
    TypeSymbol = :fixlen
    DataType   = CA_FIXLEN
  end

end

class CArray
  extend DataTypeExtension
  TypeSymbol = nil
  DataType   = nil
end

class CArray
  
  module DataTypeNewConstructor
    
    def new (*shape)
      CArray.new(self::DataType, shape)
    end
    
  end
  
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
      CArray.new(self::DataType || CA_FLOAT64, shape).zero
    end

    def ones (*shape)
      CArray.new(self::DataType || CA_FLOAT64 , shape).one
    end
    
    def eye (n, m = nil, k = 0)
      m ||= n
      mat = CArray.new(self::DataType || CA_FLOAT64, [n, m])
      start = k > 0 ? k : m - k - 1
      mat[[start..-1,m+1]] = 1
      mat
    end
    
    def identity (n)
      mat = CArray.new(self::DataType || CA_FLOAT64, [n, n])
      mat[[nil,n+1]] = 1
      mat      
    end
  
    def linspace (x1, x2, n = 100)
      data_type = self::DataType
      unless data_type
        guess = guess_data_type_from_values(x1, x2)
        guess = CA_FLOAT64 if guess == CA_INT64
        data_type = guess
      end
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
      data_type = self::DataType
      data_type ||= guess_data_type_from_values(start, stop, step)
      CArray.__new__(data_type, start..stop, step)
    end
  
    def full (shape, fill_value)
      data_type = self::DataType
      data_type ||= guess_data_type_from_values(fill_value)
      shape = [shape] unless shape.is_a?(Array)
      CArray.new(data_type, shape).fill(fill_value)
    end
  
  end
  
end

class CArray
  
  def self.meshgrid (*args)
    dim = args.map(&:size)
    out = []
    args.each_with_index do |arg, i|
      newdim = dim.dup
      newdim[i] = :%
      out[i] = arg[*newdim].to_ca
    end
    return *out
  end
  
end
