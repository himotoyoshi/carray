# ----------------------------------------------------------------------------
#
#  carray/broadcast.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CArray

  def broadcast_to (*newdim)
    
    if newdim.size < ndim
      raise "(Broadcasting) can't broadcast to #{newdim.inspect} because too small rank is specified"
    end

    #
    # Try to build unbound repeat index (includes :*)
    #                     with broadcasting rule in Numpy.
    #
    repdim = []
    shape  = []

    srcdim = dim.dup 
    dstdim = newdim.dup
    sd = srcdim.pop
    dd = dstdim.pop
    while dd
      if sd == dd
        repdim.unshift nil
        shape.unshift(dd)
        sd = srcdim.pop
      elsif dd == 1
        repdim.unshift :*
      elsif sd == 1 
        repdim.unshift :*
        sd = srcdim.pop
      else
        raise "(Broadcasting) can't broadcast to #{newdim.inspect} " 
      end
      dd = dstdim.pop
    end

    #
    # Call Unbound repeat's bind
    #
    return self.reshape(*shape)[*repdim].bind(*newdim) if repdim.include?(:*)
    
    self
  end

end

class CScalar
  
  def broadcast_to (*newdim)
    out = CArray.new(data_type, newdim, bytes: bytes)
    out[] = self
    out
  end

end

class CAUnboundRepeat

  alias broadcast_to bind

end

def CArray.broadcast (*argv, keep_scalar: true, &block)
  
  sel = argv.select { |arg| arg.is_a?(CArray) }
  return argv if sel.empty?
  
  dim = []
  ndim = sel.map(&:ndim).max
  ndim.times do |k|
    dim[k] = sel.map { |arg| arg.dim[k] || 1 }.max
  end

  if keep_scalar
    list = argv.map { |arg| 
      case arg
      when CScalar
        arg
      when CArray
        arg.broadcast_to(*dim)
      else
        arg
      end
    }
  else
    list = argv.map { |arg| arg.is_a?(CArray) ? arg.broadcast_to(*dim) : arg }
  end
  
  return block.call(*list) if block
  return list
end

