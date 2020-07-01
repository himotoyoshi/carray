# ----------------------------------------------------------------------------
#
#  carray/basic.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

module CAMath
  include Math
end

#
# monkey patch
#

def nan
  0.0/0.0
end

class Array                          # :nodoc:
  def +@
    return CA_SIZE(self)
  end
  def to_ca
    return CA_OBJECT(self)
  end
end

class Range                          # :nodoc: 
  def +@
    return CA_SIZE(self)    
  end
  def to_ca
    return CA_OBJECT(self)
  end
end

class Numeric
  
  def eq (other)
    case other
    when CArray
      return other.eq(self)
    else
      return send(:eq, *other.coerce(self))
    end
  end

  def ne (other)
    case other
    when CArray
      return other.ne(self)
    else
      return send(:ne, *other.coerce(self))
    end
  end
  
end

class CArray

  def has_attribute?
    if ( not @attribute ) or @attribute.empty?
      return false
    else
      return true
    end
  end

  def attribute= (obj)
    unless obj.is_a?(Hash)
      raise "attribute should be a hash object"
    end
    @attribute = obj
  end

  def attribute
    @attribute ||= {}
    return @attribute
  end
  
  def first
    self[0]
  end
  
  def last
    self[-1]
  end

  # matchup

  def matchup (ref)
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.bsearch(self)
    return ri.project(si)
  end

  def matchup_nearest (ref, direction: "round")
    ri = ref.sort_addr
    rs = ref[ri].to_ca
    si = rs.section(self).send(direction.intern).int64
    si.trim!(0,si.size)
    return ri[si].to_ca
  end


  # index / indices / axes

  def address ()
    return CArray.int32(*dim).seq!
  end

  def index (n = 0)
    unless n.is_a?(Integer)
      raise ArgumentError, "argument should be an integer"
    end
    if n.between?(0, ndim-1)
      return CArray.int32(dim[n]).seq!
    else
      raise ArgumentError,
            "invalid dimension specifier #{n} (0..#{self.ndim-1})"
    end
  end

  #
  #
  #

  def indices
    list = Array.new(ndim) {|i|
      rpt = self.dim
      rpt[i] = :%
      index(i)[*rpt]
    }
    if block_given?
      return yield(*list)
    else
      return list
    end
  end

    

end

class CArray

  # Returns object carray has elements of splitted carray at dimensions 
  #      which is given by arguments
  #
  #    a = CA_INT([[1,2,3], [4,5,6], [7,8,9]])
  #
  #    a.split(0) 
  #      [1,2,3], [4,5,6], [7,8,9]
  #
  #    a.split(1)
  #      [1,4,7], [2,5,8], [3,6,9]
  #

  def split (*argv)
    odim = dim.values_at(*argv)
    out  = CArray.object(*odim)
    idx  = [nil] * ndim
    attach {
      out.map_with_index! do |o, v|
        argv.each_with_index do |r, i|
          idx[r] = v[i]
        end
        self[*idx].to_ca
      end
    }
    return out
  end

end

class CAUnboundRepeat

  def template (*argv, &block)
    return parent.template(*argv,&block)[*spec.map{|x| x != :* ? nil : x}]
  end

end




