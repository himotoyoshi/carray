


class CArray

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