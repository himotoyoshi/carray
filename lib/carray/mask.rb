# ----------------------------------------------------------------------------
#
#  carray/mask.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray
  
  # mask
  
  #
  # Returns the number of masked elements.
  #

  def count_masked (*axis)
    if has_mask?  
      return mask.int64.accumulate(*axis)
    else
      if axis.empty?
        return 0
      else
        spec = shape.map{:i}
        axis.each do |k|
          spec[k] = nil
        end
        return self[*spec].ca.template(:int64) { 0 }
      end
    end
  end

  #
  # Returns the number of not-masked elements.
  #
  def count_not_masked (*axis)
    if has_mask?
      return mask.not.int64.accumulate(*axis)
    else
      if axis.empty?
        return elements
      else
        spec = shape.map {:i}
        axis.each do |k|
          spec[k] = nil
        end
        it = self[*spec].ca
        count = self.elements/it.elements
        return it.template(:int64) { count }
      end
    end
  end

  def maskout! (*argv)
    case argv.size
    when 1
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
    case argv.size
    when 1
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
  
end