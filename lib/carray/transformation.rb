# ----------------------------------------------------------------------------
#
#  carray/composition.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray
  
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

  
end