# ----------------------------------------------------------------------------
#
#  carray/test.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
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

end