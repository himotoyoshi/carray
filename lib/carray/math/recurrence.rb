# ----------------------------------------------------------------------------
#
#  carray/math/recurrence.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require 'carray'

class CARecurrence < CAObject # :nodoc:

  #
  # init should be a hash like,
  #  * [0] => 1, [1] => 1 ...
  #  * [0,0] => 1, [0,1] => 2 ...
  #

  def initialize (data, init = {}, &block)
    @value = data
    @flag = CArray.boolean(*data.dim)
    @block = block
    init.each do |idx, val|
      @value[*idx] = val
      @flag[*idx] = 1
    end
    super(data.data_type, data.dim, :bytes => data.bytes, :read_only => true)
  end

  def reset (init = {})
    @flag[] = 0
    init.each do |idx, val|
      @value[*idx] = val
      @flag[*idx] = 1
    end
  end

  private

  def fetch_addr (addr)
    if @flag[addr] == 1
      return @value[addr]
    else
      idx = addr2index(addr)
      val = @block[@value, *idx]
      @value[addr] = val
      @flag[idx] = 1
      return val
    end
  end

  def copy_data (data)
    each_addr do |addr|
      fetch_addr(addr)
    end
    data[] = @value
  end

end

class CArray

  def recurrence! (init = {}, &block)
    lazy = CARecurrence.new(self, init, &block)
    CArray.attach(lazy) {}
    return self
  end

  def recurrence (*argv, &block)
    return self.template.recurrence!(*argv, &block)
  end

end

if __FILE__ == $0

  x = 0.5
  leg = CArray.float(24).recurrence!([0]=>1, [1]=>x) { |a, i|
    w  = x * a[i-1]
    wy = w - a[i-2]
    wy+w-wy/i
  }

  p leg

  CA.gnuplot { |g|
    g.plot2d([leg.address, leg, nil, "linespoints"])
  }

end

