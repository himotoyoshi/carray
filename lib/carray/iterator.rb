# ----------------------------------------------------------------------------
#
#  carray/iterator.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

class CAIterator

  include Enumerable 

  def self.define_evaluate_method (name)
    define_method(name) { |*args|
      self.evaluate(name, *args) 
    }
  end

  [
    :axes!,
    :normalize!,
    :random!,
    :reverse!,
    :roll!,
    :scale!,
    :seq!,
    :shift!,
    :shuffle!,
    :sort!,
    :span!,
    :transpose!,
  ].each do |name|
    define_evaluate_method(name)
  end

  def self.define_filter_method (data_type, name)
    define_method(name) { |*args|
      _data_type = data_type || self.reference.data_type
      self.filter(_data_type, name, *args) 
    }
  end

  [
    [:axes      ],
    [:normalize ],
    [:random    ],
    [:reverse   ],
    [:roll      ],
    [:scale     ],
    [:seq       ],
    [:shift     ],
    [:shuffle   ],
    [:sort      ],
    [:span      ],
    [:transpose ],
  ].each do |name, data_type|
    define_filter_method(data_type, name)
  end

  def self.define_calculate_method (data_type, name)
    define_method(name) { |*args|
      _data_type = data_type || self.reference.data_type
      self.calculate(_data_type, name, *args) 
    }
  end

  [
    [:count_masked,     CA_INT32],
    [:count_not_masked, CA_INT32],
    [:count_true,       CA_INT32],
    [:count_false,      CA_INT32],
    [:size,             CA_INT32],
    [:min,              nil],
    [:min_addr,         CA_INT32],
    [:max,              nil],
    [:max_addr,         CA_INT32],
    [:prod,             CA_FLOAT64],
    [:sum,              CA_FLOAT64],
    [:wsum,             CA_FLOAT64],
    [:mean,             CA_FLOAT64],
    [:wmean,            CA_FLOAT64],
    [:variancep,        CA_FLOAT64],
    [:variance,         CA_FLOAT64],
    [:stddevp,          CA_FLOAT64],
    [:stddev,           CA_FLOAT64],
    [:median,           CA_FLOAT64],
    [:accumulate,       nil],
    [:cummin,           nil],
    [:cummax,           nil],
    [:cumcount,         CA_FLOAT64],
    [:cumprod,          CA_FLOAT64],
    [:cumsum,           CA_FLOAT64],
    [:cumwsum,          CA_FLOAT64],
    [:count_equal,      CA_INT32],
    [:count_equiv,      CA_INT32],
    [:count_close,      CA_INT32],
    [:all_equal?,       CA_BOOLEAN],
    [:any_equal?,       CA_BOOLEAN],
    [:none_equal?,      CA_BOOLEAN],
    [:all_equiv?,       CA_BOOLEAN],
    [:any_equiv?,       CA_BOOLEAN],
    [:none_equiv?,      CA_BOOLEAN],
    [:all_close?,       CA_BOOLEAN],
    [:any_close?,       CA_BOOLEAN],
    [:none_close?,      CA_BOOLEAN],
    [:nearest_addr,     CA_INT32],
    [:mul_add,          nil],
  ].each do |name, data_type|
    define_calculate_method(data_type, name)
  end

  # -----------------------------------------------------------

  def ca
    @iterary ||= CAIteratorArray.new(self)
    return @iterary
  end

  def to_a
    return ca.to_a
  end

  def pick (*idx)
    out = prepare_output(reference.data_type, :bytes=>reference.bytes)
    elements.times do |addr|
      blk = kernel_at_addr(addr)
      out[addr] = blk[*idx]
    end
    return out
  end

  def asign! (val)
    each do |elem|
      elem[] = val
    end
    return self
  end

  def [] (*idx)
    if idx.any?{|x| x.is_a?(Symbol) }
      return ca[*idx]
    else
      case idx.size
      when 0
        return clone
      when 1
        return kernel_at_addr(idx[0])
      else
        return kernel_at_index(idx)
      end
    end
  end

  def []= (*idx)
    val = idx.pop
    if idx.any?{|x| x.is_a?(Symbol) }
      ca[*idx] = [val]
    else
      case idx.size
      when 0
        asign!(val)
      when 1
        kernel_at_addr(idx[0])[] = val
      else
        kernel_at_index(idx)[] = val
      end
    end
  end

  def put (*idx)
    val = idx.pop
    elements.times do |addr|
      blk = kernel_at_addr(addr)
      blk[*idx] = val
    end
    return self
  end

  def convert (data_type, options={})
    out = prepare_output(data_type, options)
    out.map_addr!{ |addr|
      blk = kernel_at_addr(addr)
      yield(blk.clone)
    }
    return out
  end

  def each ()
    retval = nil
    if self.class::UNIFORM_KERNEL
      reference.attach! {
        blk = kernel_at_addr(0)
        elements.times do |addr|
          kernel_move_to_addr(addr, blk)
          retval = yield(blk.clone)
        end
      }
    else
      elements.times do |addr|
        retval = yield(kernel_at_addr(addr).clone)
      end
    end
    return retval
  end

  def each_with_addr ()
    retval = nil
    if self.class::UNIFORM_KERNEL
      reference.attach! {
        elements.times do |addr|
          blk = kernel_at_addr(addr)
          retval = yield(blk.clone, addr)
        end
      }
    else
      elements.times do |addr|
        retval = yield(kernel_at_addr(addr).clone, addr)
      end
    end
    return retval
  end

  def each_with_index ()
    retval = nil
    if self.class::UNIFORM_KERNEL
      reference.attach! {
        CArray.each_index(*dim) do |*idx|
          blk = kernel_at_index(idx)
          retval = yield(blk.clone, idx)
        end
      }
    else
      CArray.each_index(*dim) do |*idx|
        retval = yield(kernel_at_index(idx).clone, idx)
      end
    end
    return retval
  end

  def inject (*argv)
    case argv.size
    when 0
      memo = nil
      each_with_addr do |val, addr|
        if addr == 0
          memo = val
        else
          memo = yield(memo, val)
        end
      end
      return memo
    when 1
      memo = argv.first
      each do |val|
        memo = yield(memo, val)
      end
      return memo
    else
      raise "invalid number of arguments (#{argv.size} for 0 or 1)"
    end
  end

  def sort_by! (&block)
    ia = self.ca
    ia[] = ia.to_a.sort_by(&block).map{|x| x.to_ca }
    return reference
  end

  def sort_by (&block)
    out = reference.template
    idx = ca.convert(:object, &block).sort_addr
    ca[idx].each_with_addr do |blk, i|
      kernel_at_addr(i, out)[] = blk
    end
    return out
  end

  def sort_with (&block)
    warn "CAIterator#sort_with will be obsolete"
    out = reference.template
    idx = CA.sort_addr(*yield(self))
    ca[idx].each_with_addr do |blk, i|
      kernel_at_addr(i, out)[] = blk
    end
    return out
  end

end


# -----------------------------------------------------------------

class CArray
  def windows (*args, &block)
    return CAWindowIterator.new(self.window(*args, &block))
  end
end

# -----------------------------------------------------------------

class CArray
  
  def classes (classifier=nil, &block)
    return CAClassIterator.new(self, classifier).__build__(&block)
  end
  
end

class CAClassIterator < CAIterator # :nodoc:
  
  UNIFORM_KERNEL = false
  
  def initialize (reference, classifier = nil)
    @reference = reference
    @classifier = classifier || @reference.uniq.sort
    @null = CArray.new(@reference.data_type,[0])
    @table = {}
    @ndim = 1
    @dim  = [0]
    if @classifier.all_masked? or @classifier.size == 0
      @dim  = [0]
    else
#      @dim  = [@classifier.max+1]
      @dim  = [@classifier.size]
    end
  end
  
  attr_reader :classifier, :table
  
  def __build__ (&block)
    if @block
      @classifier.each_with_addr do |v, i|
        @table[v] = block[v].where
      end
    else
      @classifier.each_with_addr do |v, i|
        @table[v] = @reference.eq(v).where
      end
    end
    return self
  end
  
  def ndiming (&block)
    block ||= lambda {|a| a.size }
    values = self.to_a.map{|v| block[v] }.to_ca
    addrs  = values.sort_addr.reverse
    return CArray.join([@classifier[addrs], values[addrs]])
  end

  def kernel_at_addr (addr, ref = nil)
    ref ||= @reference
    if @table[addr]
      return ref[@table[addr]]
    else
      return @null
    end
  end

  def kernel_at_index (idx, ref = nil)
    kernel_at_addr(idx[0], ref)
  end

end

