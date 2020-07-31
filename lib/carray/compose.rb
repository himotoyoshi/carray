# ----------------------------------------------------------------------------
#
#  carray/composition.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray
  
  # Returns the array resized to the dimension given as `newdim`.
  # The new area is filled by the value returned by the block.
  def resize (*newdim, &block)
    if newdim.size != ndim
      raise "ndim mismatch"
    end
    offset = Array.new(ndim){0}
    ndim.times do |i|
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
    out.data_class = data_class if has_data_class?
    if out.has_mask?
      out.mask.paste(offset, self.false)
    end
    out.paste(offset, self)
    return out
  end

  # insert
  def insert_block (offset, bsize, &block)
    if offset.size != ndim or
        bsize.size != ndim
      raise "ndim mismatch"
    end
    newdim = dim
    grids = dim.map{|d| CArray.int32(d) }
    ndim.times do |i|
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
    out.data_class = data_class if has_data_class?
    if block_given?
      sel = out.true
      sel[*grids] = 0
      out[sel] = block.call
    end
    out[*grids] = self
    return out
  end

  def delete_block (offset, bsize)
    if offset.size != ndim or
      bsize.size != ndim
      raise "ndim mismatch"
    end
    newdim = dim
    grids  = []
    ndim.times do |i|
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
  
  def self.combine (data_type, tdim, list, at = 0, bytes: nil)
    if CArray.data_class?(data_type)
      data_class = data_type
      data_type  = :fixlen
      bytes = data_class::DATA_SIZE
    else
      data_class = nil
    end
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
    ndim  = ref.ndim
    tndim = tdim.size
    if at < 0
      at += ndim - tndim + 1
    end
    unless at.between?(0, ndim - tndim)
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
    newdim[at,tndim] = edim     # extended dimension size
    if has_fill_value
      obj = CArray.new(data_type, newdim) { fill_value }
    else      
      obj = CArray.new(data_type, newdim)
    end
    out.data_class = data_class if data_class
    idx = newdim.map{0}
    block.each_with_index do |item, tidx|
      (at...at+tndim).each_with_index do |d,i|
        idx[d] = offset[i][tidx[i]]
      end
      obj.paste(idx, item)
    end
    obj
  end

  def self.bind (data_type, list, at = 0, bytes: nil)
    return CArray.combine(data_type, [list.size], list, at, bytes: bytes)
  end

  def self.composite (data_type, tdim, list, at = 0, bytes: nil)
    if CArray.data_class?(data_type)
      data_class = data_type
      data_type  = :fixlen
      bytes = data_class::DATA_SIZE
    else
      data_class = nil
    end
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
    ndim  = ref.ndim
    if at < 0
      at += ndim + 1 #  "+ 1" is needed here
    end
    unless at.between?(0,ndim)
      raise "tiling position is out of range"
    end
    tndim = tdim.size
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
    obj = CArray.new(data_type, newdim, bytes: bytes)
    out.data_class = data_class if data_class
    idx = Array.new(ndim+tndim) { nil }
    CArray.each_index(*tdim) do |*tidx|
      idx[at,tndim] = tidx
      obj[*idx] = list.shift
    end
    obj
  end

  def self.merge (data_type, list, at = -1, bytes: nil)
    return CArray.composite(data_type, [list.size], list, at, bytes: bytes)
  end
  
  def self.join (*argv)
    # get options
    case argv.first
    when Class
      if CArray.data_class?(argv.first)
        data_class = argv.shift
        data_type = "fixlen"
        bytes = data_class::DATA_SIZE
      else
        raise "#{argv.first} can not to be a data_class for CArray"
      end
    when Integer, Symbol, String
      type, = *CArray.guess_type_and_bytes(argv.shift, 0)
    else
      type = argv.flatten.first.data_type
    end
    # process
    conc = argv.map do |list|
      case list
      when CArray
        if list.ndim == 1
          list[:%,1]
        else
          list
        end
      when Array
        x0 = list.first
        if list.size == 1 and
            x0.is_a?(CArray) and
            x0.ndim == 1
          list = [x0[:%,1]]
        else
        list = list.map { |x|
          case x
          when CArray
            if x.ndim == 1
              x[:%,1]
            else
              x
            end
          when Array
            y = x.first
            if x.size == 1 and
                y.is_a?(CArray) and
                y.ndim == 1
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
  
end