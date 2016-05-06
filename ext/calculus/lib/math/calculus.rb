# ----------------------------------------------------------------------------
#
#  carray/base/calculus.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray

  def normalize (scale = nil)
    if scale
      return self / self.integrate(scale)
    else
      return self / self.sum
    end
  end

  def normalize! (scale = nil)
    self[] = normalize(scale)
    return self
  end

  def solve (sc, val, eps = 100 * Float::EPSILON)
    func = self - val
    list, output = [], []
    (0...dim0-1).each do |i|
      if func[i] == UNDEF
      elsif func[i].abs < eps and not list.include?(i-1)
        output.push(sc[i])
      elsif func[i+1] == UNDEF
      elsif i < dim0 - 1 and func[i]*func[i+1] < 0
        list.push(i)
      end
    end
    list.each do |i|
      sx = CArray.double(4)
      sy = CArray.double(4)
      sx[0], sx[3] = sc[i], sc[i+1]
      sy[0], sy[3] = func[i], func[i+1]
      sx[1], sx[2] = (2.0*sx[0]+sx[3])/3.0, (sx[0]+2.0*sx[3])/3.0
      sy[1], sy[2] = func.interpolate(sc, sx[1], :type=>"linear"), func.interpolate(sc, sx[2], :type=>"linear")
      output.push(sx.interpolate(sy, 0))
    end
    return output.uniq
  end

  def solve2 (sc, eps = 100 * Float::EPSILON)
    retvals = []
    self.dim1.times do |j|
      func = self[nil,j].to_ca
      list, output = [], []
      (0...dim0-1).each do |i|
        if func[i] == UNDEF
        elsif func[i].abs < eps and not list.include?(i-1)
          output.push(sc[i])
        elsif func[i+1] == UNDEF
        elsif i < dim0 - 1 and func[i]*func[i+1] < 0
          list.push(i)
        end
      end
      list.each do |i|
        sx = CArray.double(4)
        sy = CArray.double(4)
        sx[0], sx[3] = sc[i], sc[i+1]
        sy[0], sy[3] = func[i], func[i+1]
        sx[1], sx[2] = (2*sx[0]+sx[3])/3, (sx[0]+2*sx[3])/3
        sy[1], sy[2] = func.interpolate(sc, sx[1], :type=>"linear"), func.interpolate(sc, sx[2], :type=>"linear")
        output.push(sx.interpolate(sy, 0))
      end
      retvals << output.uniq
    end
    retvals = retvals.map{|s| s.empty? ? [nil] : s}
    return retvals
  end

  private

  def _interpolate2 (x, y, x0, y0)
    case x.size
    when 1
      return self[0, nil].interpolate(y, y0)
    when 2, 3
      return self[:i,nil].interpolate(y, y0).interpolate(x, x0)
    end
    ri = x.section(x0)
    i0 = ri.floor - 1
    if i0 < 0
      i0 = 0
    elsif i0 + 3 > x.size - 1
      i0 = x.size - 4
    end
    return self[i0..i0+3,nil][:i,nil].interpolate(y, y0).
                                         interpolate(x[i0..i0+3],x0)
  end

  public

  def interpolate2 (x, y, x0, y0)
    if x0.is_a?(Numeric) and y0.is_a?(Numeric)
      return _interpolate2(x, y, x0, y0)
    else
      x0 = CArray.wrap_readonly(x0)
      y0 = CArray.wrap_readonly(y0)
      out = CArray.double(x0.size, y0.size)
      x0.each_with_index do |xi, i|
        y0.each_with_index do |yj, j|
          out[i,j] = _interpolate2(x, y, xi, yj)
        end
      end
      return out.compact
    end
  end

end
