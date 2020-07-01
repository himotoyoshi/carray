# ----------------------------------------------------------------------------
#
#  carray/math/histogram.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

#
# N-dimensional histogram class
#

#
# c0 : b0 <= x < b1  
# c1 : b1 <= x < b2  
# c2 : b2 <= x < b3  
#

require 'carray'

class CAHistogram < CArray

  def initialize (*argv, &block)

    case argv.first
    when Integer, String, Symbol
      data_type = argv.shift
    else
      data_type = CA_INT32
    end

    scales = argv.shift
    opt    = argv.shift || {}

    option = {
      :include_upper  => false,
      :include_lowest => true,
      :offsets        => nil,
    }.update( opt )

    @include_upper  = option[:include_upper]
    @include_lowest = option[:include_lowest]    

    unless scales.kind_of?(Array)
      raise "scales should be an array of scales"
    end

    ndim = scales.size
    @scales = scales.clone
    @scales.map! { |s| CArray.wrap_readonly(s, CA_DOUBLE) }
    
    if option[:offsets]
      if option[:offsets].size == scales.size
        @offsets = option[:offsets]
      else
        raise "invalid length of offset in option"
      end
    else
      @offsets = Array.new(ndim) { 0 }
    end

    dim = Array.new(ndim) { |i| 
      case @offsets[i]
      when 0
        @scales[i].size
      when 1
        @scales[i].size + 1
      else
        raise "invalid offset value"
      end
    }
    
    super(data_type, dim, &block)

    @mid_points = Array.new(ndim) { |i|
      x = (@scales[i] + @scales[i].shifted(-1))/2
      x[0..-2].to_ca
    }

    @inner = self[*Array.new(ndim) { |i| @offsets[i]..-2 }]

  end

  attr_reader :scales, :include_lowest, :include_upper, :offsets
  attr_reader :mid_points, :inner

  alias midpoints mid_points

  def increment (*values)
    idx = Array.new(ndim) {|i|
      vi = CArray.wrap_readonly(values[i], CA_DOUBLE)
      @scales[i].bin(vi, @include_upper, @include_lowest, @offsets[i]).to_ca
    }
    incr_addr(index2addr(*idx))
    self
  end

  def add (*values)
    val = CArray.wrap_readonly(values.pop, self.data_type)
    sel = val.ne(0)
    val = val[sel].to_ca
    idx = Array.new(ndim) {|i|
      vi = CArray.wrap_readonly(values[i], CA_DOUBLE)[sel]
      @scales[i].bin(vi, @include_upper, @include_lowest, @offsets[i]).to_ca
    }
    index2addr(*idx).each_with_addr do |addr, i|
      self[addr] += val[i]
    end
    self
  end

end

class CArray
  
  def bin (val, include_upper, include_lowest, offset=0)

    scales = CArray.wrap_readonly(self, CA_DOUBLE)
    
    x = scales.section(val)
#    x.inherit_mask(val)
    unless x.is_a?(CArray)
      x = CA_DOUBLE(x)
    end

    if include_upper
      if include_lowest
        x[:eq, 0] = 0.5
      end
      xi = x.ceil.int32 - 1
    else
      xi = x.floor.int32 
    end

    case offset
    when 0
      xi[:gt, elements-1] = elements - 1
      xi[:lt, 0] = UNDEF
    when 1
      xi.add!(1)
      xi[:gt, elements] = elements
      xi[:lt, 1] = 0
    else
      raise "invalid offset value"
    end

    return xi
  end
  
end

if __FILE__ == $0

  scale = CArray.float(50).span(0..10)
  hist  = CAHistogram.new([scale, scale])

  x = CArray.float(1000000).randomn!.mul!(3).abs!
  y = CArray.float(1000000).randomn!.mul!(3).abs!

  hist.increment(x, y)

#  p scale
#  p hist
#  p hist.out_of_table
#  p hist[:i,nil].sum

  CA.gnuplot { |g|
#    g.image(hist, :title => "2D histogram test")
    g.grid3d(
      [scale, scale, hist],
      :with => "dots",
      :title => "2D histogram test")
  }

end
