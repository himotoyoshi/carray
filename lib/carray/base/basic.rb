# ----------------------------------------------------------------------------
#
#  carray/base/base.rb
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

  def range
    return (self.min)..(self.max)
  end

  def asign (*idx)
    self[*idx] = yield
    return self
  end

  # mask
  
  #
  # Returns the number of masked elements.
  #

  def count_masked (*argv)
    if has_mask?
      return mask.int32.accumulate(*argv)
    else
      return 0
    end
  end

  #
  # Returns the number of not-masked elements.
  #
  def count_not_masked (*argv)
    if has_mask?
      return mask.not.int32.accumulate(*argv)
    else
      return elements
    end
  end

  def maskout! (*argv)
    if argv.size == 1
      val = argv.first
      case val
      when CArray, Symbol
        self[val] = UNDEF
      else
        self[:eq, val] = UNDEF
      end
    else
      self[*argv] = UNDEF          
    end
    return self
  end

  def maskout (*argv)
    obj = self.to_ca
    if argv.size == 1
      val = argv.first
      case val
      when CArray, Symbol
        obj[val] = UNDEF
      else
        obj[:eq, val] = UNDEF
      end
    else
      obj[*argv] = UNDEF      
    end
    return obj
  end

  # matchup

  def matchup (ref)
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.bsearch(self)
    return ri.project(si)
  end

  def matchup_nearest (ref)
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.section(self).round.int32
    si.trim!(0,si.size)
    return ri[si].to_ca
  end

  # replace
  #
  #
  def replace (from, to)
    self[:eq, from] = to
    return self
  end

  # reshape

  def reshape (*newdim)
    ifalse = nil
    i = 0
    0.upto(newdim.size-1) do |i|
      if newdim[i].nil?
        newdim[i] = dim[i]
      elsif newdim[i] == false 
        ifalse = i
        break
      end
    end
    k = 0
    (newdim.size-1).downto(i+1) do |j|
      if newdim[j].nil?
        newdim[j] = dim[rank-1-k]
      end
      k += 1
    end
    if ifalse
      newdim[ifalse] = 
          elements/newdim.select{|x| x!=false}.inject(1){|s,x| s*x}
    end
    return refer(data_type, newdim, :bytes=>bytes)
  end

  # flatten

  def flattened
    return reshape(elements)
  end

  def flatten
    return reshape(elements).to_ca
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

  # reversed

  def reversed
    return self[*([-1..0]*rank)]
  end

  # roll / shift

  def shift! (*argv, &block)
    self[] = self.shifted(*argv, &block)
    return self
  end

  def shift (*argv, &block)
    return self.shifted(*argv, &block).to_ca
  end

  def rolled (*argv)
    argv.push({:roll => Array.new(rank){1} })
    return shifted(*argv)
  end

  def roll! (*argv)
    self[] = self.rolled(*argv)
    return self
  end

  def roll (*argv)
    return self.rolled(*argv).to_ca
  end

  def transpose! (*argv)
    self[] = self.transposed(*argv)
    return self
  end

  def transpose (*argv)
    return self.transposed(*argv).to_ca
  end

  # Reutrns the reference which rank is reduced 
  # by eliminating the dimensions which size == 1 
  def compacted
    if rank == 1
      return self[]
    else
      newdim = dim.reject{|x| x == 1 }
      return ( rank != newdim.size ) ? reshape(*newdim) : self[]
    end
  end

  # Returns the array which rank is reduced 
  # by eliminating the dimensions which size == 1 
  def compact
    if rank == 1
      return self.to_ca
    else
      newdim = dim.reject{|x| x == 1 }
      return ( rank != newdim.size ) ? reshape(*newdim).to_ca : self.to_ca
    end
  end

  # Returns the reference which elements are sorted by the comparison method
  # given as block
  def sorted_by (type=nil, opt={}, &block)
    type, bytes =
      CArray.guess_type_and_bytes(type||data_type, opt[:bytes]||bytes)
    cmpary = convert(type, :bytes=>bytes, &block)
    return self[cmpary.sort_addr]
  end

  # Returns the array which elements are sorted by the comparison method
  # given as block
  def sort_by (type=nil, opt={}, &block)
    type, bytes =
      CArray.guess_type_and_bytes(type||data_type, opt[:bytes]||bytes)
    cmpary = convert(type, :bytes=>bytes, &block)
    return self[cmpary.sort_addr].to_ca
  end

  def max_by (&block)
    if empty?
      return UNDEF
    else
      addr = convert(:object, &block).max_addr
      return self[addr]
    end
  end

  def min_by (&block)
    if empty?
      return UNDEF
    else
      addr = convert(:object, &block).min_addr
      return self[addr]
    end
  end

  # Returns (1,n) array from 1-dimensional array 
  def to_row 
    if rank != 1
      raise "rank should be 1"
    end
    return self[1,:%]
  end
  
  # Returns (n,1) array from 1-dimensional array 
  def to_column
    if rank != 1
      raise "rank should be 1"
    end
    return self[:%,1]
  end

  # Returns the array resized to the dimension given as `newdim`.
  # The new area is filled by the value returned by the block.
  def resize (*newdim, &block)
    if newdim.size != rank
      raise "rank mismatch"
    end
    offset = Array.new(rank){0}
    rank.times do |i|
      d = newdim[i]
      case d
      when nil
        newdim[i] = dim[i]
      when Integer
        if d < 0
          newdim[i] *= -1
          offset[i] = newdim[i] - dim[i]
        end
      else
        raise "invalid dimension size"
      end
    end
    out = CArray.new(data_type, newdim, &block)
    if out.has_mask?
      out.mask.paste(offset, self.false)
    end
    out.paste(offset, self)
    return out
  end

  # insert
  def insert_block (offset, bsize, &block)
    if offset.size != rank or
        bsize.size != rank
      raise "rank mismatch"
    end
    newdim = dim
    grids = dim.map{|d| CArray.int32(d) }
    rank.times do |i|
      if offset[i] < 0
        offset[i] += dim[i]
      end
      if offset[i] < 0 or offset[i] >= dim[i] or bsize[i] < 0
        raise "invalid offset or size"
      end
      if bsize[i] > 0
        newdim[i] += bsize[i]
      end
      grids[i][0...offset[i]].seq!
      grids[i][offset[i]..-1].seq!(offset[i]+bsize[i])
    end
    out = CArray.new(data_type, newdim)
    if block_given?
      sel = out.true
      sel[*grids] = 0
      out[sel] = block.call
    end
    out[*grids] = self
    return out
  end

  def delete_block (offset, bsize)
    if offset.size != rank or
      bsize.size != rank
      raise "rank mismatch"
    end
    newdim = dim
    grids  = []
    rank.times do |i|
      if offset[i] < 0
        offset[i] += dim[i]
      end
      if bsize[i] >= 0
        if offset[i] < 0 or offset[i] >= dim[i]
          raise "invalid offset or size"
        end
        newdim[i] -= bsize[i]
      else
        if offset[i] + bsize[i] + 1 < 0 or offset[i] + bsize[i] > dim[i]
          raise "invalid offset or size"
        end
        newdim[i] += bsize[i]
      end
      grids[i] = CArray.int32(newdim[i])
      if bsize[i] >= 0
        if offset[i] > 0
          grids[i][0...offset[i]].seq!
        end
        if offset[i] + bsize[i] < dim[i]
          grids[i][offset[i]..-1].seq!(offset[i]+bsize[i])
        end
      else
        if offset[i]+bsize[i] > 0
          grids[i][0..offset[i]+bsize[i]].seq!
        end
        if offset[i]+bsize[i]+1 < dim[i]-1
          grids[i][offset[i]+bsize[i]+1..-1].seq!(offset[i]+1)
        end
      end
    end
    return self[*grids].to_ca
  end

  def where_range
    w = where
    x = (w - w.shifted(1){-2}).sub!(1).where
    y = (w - w.shifted(-1){-2}).add!(1).where
    list = []
    x.each_addr do |i|
      list.push(w[x[i]]..w[y[i]])
    end
    return list
  end
  
  def order (dir = 1)
    if dir >= 0   ### ascending order
      if has_mask?
        obj = template(:int32) { UNDEF }
        sel = is_not_masked
        obj[sel][self[sel].sort_addr].seq!
        return obj
      else
        obj = template(:int32)
        obj[sort_addr].seq!
        return obj
      end
    else           ### descending order
      if has_mask?
        obj = template(:int32) { UNDEF}
        sel = is_not_masked
        obj[sel][self[sel].sort_addr.reversed].seq!
        return obj
      else  
        obj = template(:int32)
        obj[sort_addr.reversed].seq!
        return obj
      end
    end
  end

  # Returns the array eliminated all the duplicated elements.
  def uniq
    ary = to_a.uniq
    if has_mask?
      ary.delete(UNDEF)
    end
    if has_data_class?
      return CArray.new(data_class, [ary.length]) { ary }
    else
      return CArray.new(data_type, [ary.length], :bytes=>bytes) { ary }
    end
  end

  # Returns the array eliminated all the duplicated elements.
  def duplicated_values
    if uniq.size == size
      return []
    else
      hash = {}
      list = []
      each_with_addr do |v, addr|
        if v == UNDEF
          next
        elsif hash[v]
          list << [v, addr, hash[v]]
          hash[v] += 1
        else
          hash[v] = 0
        end
      end
      return list
    end
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

  def index (n)
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

  def contains (*list)
    result = self.false()
    list.each do |item|
      result = result | self.eq(item)
    end
    return result 
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

  def self.combine (data_type, tdim, list, at = 0)
    has_fill_value = false
    if block_given?
      fill_value = yield
      has_fill_value = true
    end
    if not tdim.is_a?(Array) or tdim.size == 0
      raise "invalid binding dimension"
    end
    if not list.is_a?(Array) or list.size == 0
      raise "invalid list"
    end
    list = list.map{|x| CArray.wrap_readonly(x, data_type) }
    ref  = list.detect{|x| x.is_a?(CArray) or not x.scalar? }
    unless ref
      raise "at least one element in list should be a carray"
    end
    dim   = ref.dim
    rank  = ref.rank
    trank = tdim.size
    if at < 0
      at += rank - trank + 1
    end
    unless at.between?(0, rank - trank)
      raise "concatnating position out of range"
    end
    list.map! do |x|
      if x.scalar?
        rdim = dim.clone
        rdim[at] = :%
        x = x[*rdim]        # convert CScalar to CARepeat
      end
      x
    end
    block = CArray.object(*tdim){ list }
    edim = tdim.clone
    idx = Array.new(tdim)
    offset = Array.new(tdim.size) { [] }
    tdim.each_with_index do |td, i|
      edim[i] = 0
      idx.map!{0}
      idx[i] = nil
      block[*idx].each do |e|
        offset[i] << edim[i]
        edim[i] += e.dim[at+i]  # extended dimension size
      end
    end
    newdim = dim.clone
    newdim[at,trank] = edim     # extended dimension size
    if has_fill_value
      obj = CArray.new(data_type, newdim) { fill_value }
    else      
      obj = CArray.new(data_type, newdim)
    end
    idx = newdim.map{0}
    block.each_with_index do |item, tidx|
      (at...at+trank).each_with_index do |d,i|
        idx[d] = offset[i][tidx[i]]
      end
      obj.paste(idx, item)
    end
    obj
  end

  def self.bind (data_type, list, at = 0)
    return CArray.combine(data_type, [list.size], list, at)
  end

  def self.composite (data_type, tdim, list, at = 0)
    if not tdim.is_a?(Array) or tdim.size == 0
      raise "invalid tiling dimension"
    end
    if not list.is_a?(Array) or list.size == 0
      raise "invalid carray list"
    end
    list = list.map{|x| CArray.wrap_readonly(x, data_type) }
    ref  = list.detect{|x| x.is_a?(CArray) or not x.scalar? }
    unless ref
      raise "at least one element in list should be a carray"
    end
    dim   = ref.dim
    rank  = ref.rank
    if at < 0
      at += rank + 1 #  "+ 1" is needed here
    end
    unless at.between?(0,rank)
      raise "tiling position is out of range"
    end
    trank = tdim.size
    list.map! do |x|
      if x.scalar?
        rdim = dim.clone
        rdim[at] = :%
        x = x[*rdim]     # convert CScalar to CARepeat
      end
      x
    end
    newdim = dim.clone
    newdim[at,0] = tdim
    obj = CArray.new(data_type, newdim)
    idx = Array.new(rank+trank) { nil }
    CArray.each_index(*tdim) do |*tidx|
      idx[at,trank] = tidx
      obj[*idx] = list.shift
    end
    obj
  end

  def self.merge (data_type, list, at = -1)
    return CArray.composite(data_type, [list.size], list, at)
  end
  
  def self.join (*argv)
    # get options
    case argv.first
    when Integer, Symbol, String
      type, = *CArray.guess_type_and_bytes(argv.shift, 0)
    else
      type = argv.flatten.first.data_type
    end
    # process
    conc = argv.map do |list|
      case list
      when CArray
        if list.rank == 1
          list[:%,1]
        else
          list
        end
      when Array
        x0 = list.first
        if list.size == 1 and
            x0.is_a?(CArray) and
            x0.rank == 1
          list = [x0[:%,1]]
        else
        list = list.map { |x|
          case x
          when CArray
            if x.rank == 1
              x[:%,1]
            else
              x
            end
          when Array
            y = x.first
            if x.size == 1 and
                y.is_a?(CArray) and
                y.rank == 1
              y[1,:%]
            else
              CArray.join(*x)
            end
          else
            x
          end
        }
        end
        if block_given?
          CArray.bind(type, list, 1, &block)
        else
          CArray.bind(type, list, 1)
        end 
      else
        list
      end
    end
    if conc.size > 1
      return CArray.bind(type, conc)
    else
      return conc.first
    end
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


