# ----------------------------------------------------------------------------
#
#  carray/ordering.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray
  
  # reversed
  def reversed
    return self[*([-1..0]*ndim)]
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
    argv.push({:roll => Array.new(ndim){1} })
    return shifted(*argv)
  end

  def roll! (*argv)
    self[] = self.rolled(*argv)
    return self
  end

  def roll (*argv)
    return self.rolled(*argv).to_ca
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
  
  def sorted_with (*others)
    addr = sort_addr
    ([self] + others).map { |x| x[addr] }
  end

  def sort_with (*others)
    addr = sort_addr
    ([self] + others).map { |x| x[addr].to_ca }
  end

  def max_by (&block)
    if empty?
      return UNDEF
    else
      addr = convert(:object, &block).max_addr
      return self[addr]
    end
  end

  def max_with (*others)
    if empty?
      return ([self] + others).map { |x| UNDEF }
    else
      addr = max_addr
      return ([self] + others).map { |x| x[addr] }
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

  def min_with (*others)
    if empty?
      return ([self] + others).map { |x| UNDEF }
    else
      addr = min_addr
      return ([self] + others).map { |x| x[addr] }
    end
  end

  def range 
    return (self.min)..(self.max)
  end

  def nlargest (n)
    obj = self.to_ca
    list = []
    n.times do |i|
      k = obj.max_addr
      list << obj[k]
      obj[k] = UNDEF
    end
    list.to_ca.to_type(data_type)
  end

  def nlargest_addr (n)
    obj = self.to_ca
    list = []
    n.times do |i|
      k = obj.max_addr
      list << k
      obj[k] = UNDEF
    end
    CA_INT64(list)
  end

  def nsmallest (n)
    obj = self.to_ca
    list = []
    n.times do |i|
      k = obj.min_addr
      list << obj[k]
      obj[k] = UNDEF
    end
    list.to_ca.to_type(data_type)
  end

  def nsmallest_addr (n)
    obj = self.to_ca
    list = []
    n.times do |i|
      k = obj.min_addr
      list << k
      obj[k] = UNDEF
    end
    CA_INT64(list)
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

end