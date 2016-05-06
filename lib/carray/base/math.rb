# ----------------------------------------------------------------------------
#
#  carray/base/math.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray

  # complex number

  # Return the real part of +self+.
  # If +self+ is a complex array, the resulted array is CAMember object
  # refers the appropriate part of +self+.
  # Otherwise, the resulted array is CARefer object refers +self+.
  # If you change the resulted array, the original array is also changed.
  #
  def real
    if not @__real__
      if complex?
        @__real__ = case data_type
                    when CA_CMPLX64
                      field(0, CA_FLOAT32)
                    when CA_CMPLX128
                      field(0, CA_FLOAT64)
                    when CA_CMPLX128
                      field(0, CA_FLOAT128)
                    end
      else
        @__real__ = self[]
      end
    end
    @__real__
  end

  def real= (val)
    real[] = val
  end

  # Return the imaginary part of +self+.
  # If +self+ is a complex array, the resulted array is CAMember object
  # refers the appropriate part of +self+. In this case,
  # you change the resulted array, the original array is also changed.
  #
  # Otherwise, the resulted array is a dummy CArray object filled with 0.
  # In this case, the change in the resulted array does not affect
  # the original array. For this purpose, you should explicitly convert
  # the array to complex array.
  #
  def imag
    if not @__imag__
      if complex?
        @__imag__ = case data_type
                    when CA_CMPLX64
                      field(4, CA_FLOAT32)
                    when CA_CMPLX128
                      field(8, CA_FLOAT64)
                    when CA_CMPLX128
                      field(16, CA_FLOAT128)
                    end
      else
        @__imag__ = self.template { 0 }
      end
    end
    return @__imag__
  end

  def imag= (val)
    if complex?
      imag[] = val
    else
      raise "not a complex array"
    end
  end

  # comparison operators

  def <=> (other)
    lower = self < other
    upper = self > other
    out = CArray.new(CA_INT8, lower.dim)
    out[lower] = -1
    out[upper] = 1
    return out
  end

  alias cmp <=>

  def is_equiv (other, rtol)
    exact_eq    = self.eq(other)
    relative_eq = ((self - other).abs/CAMath.max(self.abs, other.abs) <= rtol)
    return (exact_eq).or(relative_eq)
  end

  def is_close (other, atol)
    return ((self - other).abs <= atol)
  end

  def is_divisible (n)
    unless integer?
      raise "data type of reciever of CArray#divisible? should be integer."
    end
    return (self % n).eq(0)
  end

  def is_not_divisible (n)
    unless integer?
      raise "data type of reciever of CArray#divisible? should be integer."
    end
    return (self % n).ne(0)
  end

  def real?
    if complex?
      imag.all_equal?(0)
    elsif numeric?
      true
    else
      nil
    end
  end

  def is_real
    if complex?
      imag.eq(0)
    elsif numeric?
      self.true
    else
      nil
    end
  end

  def sign
    out = self.zero
    out[self.lt(0)] = -1
    out[self.gt(0)] = 1
    if float?
      out[self.is_nan] = 0.0/0.0
    end
    return out
  end
  
  def quo (other)
    case 
    when integer?
      return double/other
    when object?
      return quo_i(other)
    else
      return self/other
    end
  end
  
end


module CAMath

  module_function

  def min (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.to_ca
      argv.delete(ary)
      argv.each do |x|
        out.pmin!(x)
      end
    else
      raise "args should contain more than one CArray object"
    end
    return out
  end

  def max (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.to_ca
      argv.delete(ary)
      argv.each do |x|
        out.pmax!(x)
      end
    else
      raise "args should contain more than one CArray object"
    end
    return out
  end

end

class CArray

  #
  # statistics
  #

  def random (*argv)
    return template.random!(*argv)
  end

  def randomn!
    if elements == 1
      self[0] = CArray.new(data_type,[2]).randomn![0]
      return self
    end
    x1 = CArray.new(data_type, [elements/2])
    x2 = CArray.new(data_type, [elements/2])
    fac = x1.random!.log!.mul!(-2.0).sqrt!    ### fac = sqrt(-2*log(rnd()))
    x2.random!.mul!(2.0*Math::PI)             ### x2  = 2*PI*rnd()
    x3 = x2.to_ca
    self2 = reshape(2,elements/2)
    self2[0,nil] = x2.cos!.mul!(fac)          ### self[even] = fac*cos(x2)
    self2[1,nil] = x3.sin!.mul!(fac)          ### self[odd]  = fac*sin(x2)
    if elements % 2 == 1
      self[[-1]].randomn!
    end
    return self
  end

  def randomn
    return template.randomn!
  end

  def anomaly (*argv)
    opt = argv.last.is_a?(Hash) ? argv.pop : {}
    idxs = Array.new(self.rank) { |i| argv.include?(i) ? :* : nil }
    if mn = opt[:mean]
      return self - mn[*idxs]
    else
      return self - self.mean(*argv)[*idxs]
    end
  end

  alias anom anomaly

  def median (*argv)
    opt = argv.last.is_a?(Hash) ? argv.pop : {}
    min_count  = opt[:mask_limit]
    if min_count and min_count < 0
      min_count += elements
    end
    fill_value = opt[:fill_value]
    if argv.empty?
      if has_mask?
        if min_count and count_masked() > min_count
          return fill_value || UNDEF
        end
        c = self[:is_not_masked].sort
        n = self.count_not_masked
      else
        c = self.sort
        n = c.elements
      end
      if n == 0
        return fill_value || UNDEF
      else
        return (c[(n-1)/2] + c[n/2])/2.0
      end
    else
      raise "CArray#median is not implemented for multiple ranks"
    end

  end

  def percentile (*argv)
    opt = argv.last.is_a?(Hash) ? argv.pop : {}
    pers = argv
    min_count  = opt[:mask_limit]
    if min_count and min_count < 0
      min_count += elements
    end
    fill_value = opt[:fill_value]
    if has_mask?
      if min_count and count_masked() > min_count
        return argv.map { fill_value || UNDEF }
      end
      ca = self[:is_not_masked].sort
      n  = self.count_not_masked
    else
      ca = self.sort
      n  = ca.elements
    end
    out = []
    begin
    pers.each do |per|
      if per == 100
        out << ca[n-1]
      elsif per >= 0 and per < 100
        if n > 1
          f = (n-1)*per/100.0
          k = f.floor
          r = f - k
          out << (1-r)*ca[k] + r*ca[k+1]
        else
          out << ca[0]
        end
      else
        out << CA_NAN
      end
    end
  rescue
    p self[:is_not_masked]
    p n
    raise
  end
    return out
  end
  
  def quantile 
    return percentile(0, 25, 50, 75, 100)
  end

  def covariancep (y, min_count = nil, fill_value = nil)
    x = self.double
    y = y.double
    if x.has_mask? or y.has_mask?
      x.inherit_mask(y)
      y.inherit_mask(x)
      count = x.count_not_masked
      xm = x.mean(:min_count => min_count)
      ym = y.mean(:min_count => min_count)
      if ( xm.undef? or ym.undef? )
        return fill_value || UNDEF
      else
        return (x-xm).wsum(y-ym)/count
      end
    else
      return (x-x.mean).wsum(y-y.mean)/elements
    end
  end

  def covariance (y, min_count = nil, fill_value = nil)
    x = self.double
    y = y.double
    if x.has_mask? or y.has_mask?
      x.inherit_mask(y)
      y.inherit_mask(x)
      count = x.count_not_masked
      xm = x.mean(:min_count=>min_count)
      ym = y.mean(:min_count=>min_count)
      if ( xm.undef? or ym.undef? )
        return fill_value || UNDEF
      else
        return (x-xm).wsum(y-ym)/(count-1)
      end
    else
      return (x-x.mean).wsum(y-y.mean)/(elements-1)
    end
  end

  def correlation (y, min_count = nil, fill_value = nil)
    x = self.double
    y = y.double
    if x.has_mask? or y.has_mask?
      x.inherit_mask(y)
      y.inherit_mask(x)
      xm = x.mean(:min_count=>min_count)
      ym = y.mean(:min_count=>min_count)
      if ( xm.undef? or ym.undef? )
        return fill_value || UNDEF
      else
        xd, yd = x-xm, y-ym
        return xd.wsum(yd)/(xd.wsum(xd)*yd.wsum(yd)).sqrt
      end
    else
      xd, yd = x-x.mean, y-y.mean
      return xd.wsum(yd)/(xd.wsum(xd)*yd.wsum(yd)).sqrt
    end
  end

end

class CArray

  def self.summation (*dim)
    out = nil
    first = true
    CArray.each_index(*dim) { |*idx|
      if first
        out = yield(*idx)
        first = false
      else  
        out += yield(*idx)
      end
    }
    return out
  end
  
  def by (other)
    case other
    when CArray
      return (self[nil][nil,:*]*other[nil][:*,nil]).reshape(*(dim+other.dim))
    else
      return self * other
    end
  end
  
end


