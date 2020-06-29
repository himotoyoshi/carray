# ----------------------------------------------------------------------------
#
#  carray/basic.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

module CAMath
  include Math
end

#
# monkey patch
#

def nan
  0.0/0.0
end

class Array                          # :nodoc:
  def +@
    return CA_SIZE(self)
  end
  def to_ca
    return CA_OBJECT(self)
  end
end

class Range                          # :nodoc: 
  def +@
    return CA_SIZE(self)    
  end
  def to_ca
    return CA_OBJECT(self)
  end
end

class Numeric
  
  def eq (other)
    case other
    when CArray
      return other.eq(self)
    else
      return send(:eq, *other.coerce(self))
    end
  end

  def ne (other)
    case other
    when CArray
      return other.ne(self)
    else
      return send(:ne, *other.coerce(self))
    end
  end
  
end

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
def CArray.__new__ (type, *args) # :nodoc:
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

def CArray.__new_fixlen__ (bytes, v) # :nodoc:
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

  def has_attribute?
    if ( not @attribute ) or @attribute.empty?
      return false
    else
      return true
    end
  end

  def attribute= (obj)
    unless obj.is_a?(Hash)
      raise "attribute should be a hash object"
    end
    @attribute = obj
  end

  def attribute
    @attribute ||= {}
    return @attribute
  end
  
  def first
    self[0]
  end
  
  def last
    self[-1]
  end

  # matchup

  def matchup (ref)
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.bsearch(self)
    return ri.project(si)
  end

  def matchup_nearest (ref, direction: "round")
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.section(self).send(direction.intern).int64
    si.trim!(0,si.size)
    return ri[si].to_ca
  end

  # replace_value
  #
  #
  def replace_value (from, to)
    self[:eq, from] = to
    return self
  end

  # pulled

  def pulled (*args)
    idx = args.map{|s| s.nil? ? :% : s}
    return self[*idx]
  end
  
  def pull (*args)
    idx = args.map{|s| s.nil? ? :% : s}
    return self[*idx].to_ca
  end

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
    if range.exclude_end?
      seq!(first, (last-first)/elements)
    else
      seq!(first, (last-first)/(elements-1))
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

  # index / indices / axes

  def address ()
    return CArray.int32(*dim).seq!
  end

  def index (n = 0)
    unless n.is_a?(Integer)
      raise ArgumentError, "argument should be an integer"
    end
    if n.between?(0, rank-1)
      return CArray.int32(dim[n]).seq!
    else
      raise ArgumentError,
            "invalid dimension specifier #{n} (0..#{self.rank-1})"
    end
  end

  #
  #
  #

  def indices
    list = Array.new(rank) {|i|
      rpt = self.dim
      rpt[i] = :%
      index(i)[*rpt]
    }
    if block_given?
      return yield(*list)
    else
      return list
    end
  end

  #
  # Returns the 8-bit integer CArray object filled with 0 which
  # dimension size is same as +self+. The resulted array represents
  # the logical array which has +false+ for its all elements.
  #
  def false ()
    return template(:boolean)
  end

  #
  # Returns the 8-bit integer CArray object filled with 1 which
  # dimension size is same as +self+. The resulted array represents
  # the logical array which has +true+ for its all elements.
  #
  def true ()
    return template(:boolean) { 1 }
  end

  # Returns map
  def map (&block)
    return self.convert(CA_OBJECT, &block).to_a
  end

  # Array#join like method
  #
  # > a = CArray.object(3,3).seq("a",:succ)
  # => <CArray.object(3,3): elem=9 mem=72b
  # [ [ "a", "b", "c" ],
  #   [ "d", "e", "f" ],
  #   [ "g", "h", "i" ] ]>
  # 
  # > a.join("\n",",")
  # => "a,b,c\nd,e,f\ng,h,i"
  #

  def join (*argv)
    case argv.size
    when 0
      return to_a.join()
    when 1
      sep = argv.shift
      return to_a.join(sep)
    else
      sep = argv.shift
      return self[:i, false].map { |s|
          s[0, false].join(*argv)
      }.join(sep)
    end
  end
    
  # 
  def to_bit_string (nb)
    hex = CArray.uint8(((nb*elements)/8.0).ceil)
    hex.bits[nil].paste([0], self.bits[false,[(nb-1)..0]].flatten)
    hex.bits[] = hex.bits[nil,[-1..0]]
    return hex.to_s
  end

  def from_bit_string (bstr, nb)
    hex = CArray.uint8(bstr.length).load_binary(bstr)
    hex.bits[] = hex.bits[nil,[-1..0]]
    bits = hex.bits.flatten
    self.bits[false,[(nb-1)..0]][nil].paste([0], bits)
    return self
  end

  def self.from_bit_string (bstr, nb, data_type=CA_INT32, dim=nil)
    if dim
      obj = CArray.new(data_type, dim)
    else
      dim0 = ((bstr.length*8)/nb.to_f).floor
      obj = CArray.new(data_type, [dim0])
    end
    obj.from_bit_string(bstr, nb)
    return obj
  end

end

class CArray

  #
  #  ref = CA_INT([[0,1,2],[1,2,0],[2,0,1]])
  #  a = CArray.int(3,3).seq(1)
  #  b = CArray.int(3,3).seq(11)
  #  c = CArray.int(3,3).seq(21)
  #
  #  CArray.pickup(CA_OBJECT, ref, [a,b,c])
  #  => <CArray.object(3,3): elem=9 mem=72b
  #  [ [ 1, 12, 23 ],
  #    [ 14, 25, 6 ],
  #    [ 27, 8, 19 ] ]>
  #
  #  CArray.pickup(CA_OBJECT, ref, ["a","b","c"])
  #  => <CArray.object(3,3): elem=9 mem=36b
  #  [ [ "a", "b", "c" ],
  #    [ "b", "c", "a" ],
  #    [ "c", "a", "b" ] ]>
  #
  def self.pickup (data_type, ref, args)
    out = ref.template(data_type)
    args.each_with_index do |v, i|
      s = ref.eq(i)
      case v
      when CArray
        out[s] = v[s]
      else
        out[s] = v
      end
    end
    return out
  end

  # Returns object carray has elements of splitted carray at dimensions 
  #      which is given by arguments
  #
  #    a = CA_INT([[1,2,3], [4,5,6], [7,8,9]])
  #
  #    a.split(0) 
  #      [1,2,3], [4,5,6], [7,8,9]
  #
  #    a.split(1)
  #      [1,4,7], [2,5,8], [3,6,9]
  #

  def split (*argv)
    odim = dim.values_at(*argv)
    out  = CArray.object(*odim)
    idx  = [nil] * rank
    attach {
      out.map_with_index! do |o, v|
        argv.each_with_index do |r, i|
          idx[r] = v[i]
        end
        self[*idx].to_ca
      end
    }
    return out
  end

end

class CAUnboundRepeat

  def template (*argv, &block)
    return parent.template(*argv,&block)[*spec.map{|x| x != :* ? nil : x}]
  end

end


module CA
  
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


