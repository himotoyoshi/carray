# ----------------------------------------------------------------------------
#
#  carray/test.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray

  def test (&block)
    return convert(:boolean) {|v| yield(v) ? true : false }
  end

  def contains (*list)
    result = self.false()
    list.each do |item|
      result = result | self.eq(item)
    end
    return result 
  end

  def between (a, b)
    return (self >= a) & (self <= b)
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
  
  # Returns the array eliminated all the duplicated elements.
  def uniq
    ary = flatten.to_a.uniq
    if has_mask?
      ary.delete(UNDEF)
    end
    if has_data_class?
      return CArray.new(data_class, [ary.length]) { ary }
    else
      return CArray.new(data_type, [ary.length], :bytes=>bytes) { ary }
    end
  end


end