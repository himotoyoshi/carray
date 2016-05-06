# ----------------------------------------------------------------------------
#
#  carray/math/narray_miss.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "narray_miss"

class CArray

  def to_nam
    if has_mask?
      return NArrayMiss.to_nam_no_dup(to_na, mask.bit_neg.na)
    else
      return NArrayMiss.to_nam_no_dup(to_na)
    end
  end

  def to_nam!
    if has_mask?
      return NArrayMiss.to_nam_no_dup(to_na!, mask.bit_neg.to_na!)
    else
      return NArrayMiss.to_nam_no_dup(to_na!)
    end
  end

end

class NArrayMiss

  def to_ca
    ca = @array.to_ca
    ca.mask = @mask.ca
    ca.mask.bit_neg!
    return ca
  end

end

