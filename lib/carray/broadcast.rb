
class CArray
  def broadcast_to (*new_dim)
    if new_dim.size < ndim
      raise "can't broadcast to #{new_dim.inspect} because of mismatch in rank"
    end
    flag_unbound_repeat = false
    sdim = []
    ([1]*(new_dim.size-ndim) + dim).each_with_index do |d, k|
      if new_dim[k] == 1
        sdim << 1
      elsif d == 1
        flag_unbound_repeat = true
        sdim << :*
      elsif d != new_dim[k]
        raise "can't broadcast to #{new_dim.inspect} because of mismatch in #{d} for #{new_dim[k]} in #{k}th dim"
      else
        sdim << nil
      end
    end
    return self[*sdim].bind(*new_dim) if flag_unbound_repeat
    return self
  end
end

class CScalar
  def broadcast_to (*new_dim)
    return self
  end
end

class CAUnboundRepeat
  alias broadcast_to bind
end

def CArray.broadcast (*argv)
  dim = []
  ndim = argv.map(&:ndim).max
  ndim.times do |k|
    dim[k] = argv.map{|arg| arg.dim[k] || 1 }.max
  end
  return argv.map{|arg| arg.broadcast_to(*dim) }
end
