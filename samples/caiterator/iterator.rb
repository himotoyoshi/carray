class CAIterator

  # No `include Enumerable`: the family surface is fully explicit per iterator
  # (named reductions + each / map / reduce), so Enumerable's reduction-like
  # names (min / max / sum / count / minmax / to_a / ...) do not leak in and
  # silently fold the pieces. A method an iterator does not define is a clean
  # NoMethodError, not a wrong answer.

  def self.define_evaluate_method (name)
    define_method(name) { |*args|
      self.evaluate(name, *args) 
    }
  end

  [
    :axes!,
    :normalize!,
    :random!,
    :scale!,
    :seq!,
    :shuffle!,
    :span!,
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
    # count(v) replaces count_true / count_false / count_equal in CF.7.
    # iter.count(true) / iter.count(false) / iter.count(value) all route
    # through the same CArray#count dispatcher.
    [:count,            CA_INT32],
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
    # count_equal / count_equiv / count_close removed in CF.7.
    # Use iter.count(v) for count_equal, or apply chain at the CArray
    # layer before iteration for count_close / count_equiv:
    #   iter.count(v)                          # was count_equal(v)
    #   ca.is_close(v, t).iter(...).count(true)  # was count_close(v, t)
    #   ca.is_equiv(v, t).iter(...).count(true)  # was count_equiv(v, t)
    [:nearest_addr,     CA_INT32],
  ].each do |name, data_type|
    define_calculate_method(data_type, name)
  end

  # -----------------------------------------------------------

  # @overload pick(*idx)
  #   Returns a new CArray shaped like {#reference} whose cell at
  #   outer address `addr` holds the sub-kernel value at `idx`.
  #   @param idx [Array<Integer>] inner index into each kernel.
  #   @return [CArray]
  def pick (*idx)
    out = prepare_output(reference.data_type, :bytes=>reference.bytes)
    elements.times do |addr|
      blk = kernel_at_addr(addr)
      out[addr] = blk[*idx]
    end
    return out
  end

  # @overload asign!(val)
  #   Sets every kernel to `val`.
  #   @param val [Object]
  #   @return [self]
  def asign! (val)
    each do |elem|
      elem[] = val
    end
    return self
  end

  # @overload [](*idx)
  #   Returns a kernel or slice from `self`. With no arguments,
  #   returns a shallow clone; with one argument, the kernel at
  #   that address; with several, the kernel at that N-D index.
  #   Symbol indices delegate to `ca[*idx]`.
  #   @param idx [Array<Integer, Symbol>]
  #   @return [CArray, CAIterator]
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

  # @overload []=(*idx, val)
  #   Sets the addressed kernel (or entire iterator with no index)
  #   to `val`. Mirrors {#[]}.
  #   @param idx [Array<Integer, Symbol>]
  #   @param val [Object] value to assign.
  #   @return [Object] `val`.
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

  # @overload put(*idx, val)
  #   Assigns `val` at position `idx` of every kernel.
  #   @param idx [Array<Integer>] inner index.
  #   @param val [Object]
  #   @return [self]
  def put (*idx)
    val = idx.pop
    elements.times do |addr|
      blk = kernel_at_addr(addr)
      blk[*idx] = val
    end
    return self
  end

  # @overload convert(data_type, options = {}) { |kernel| ... }
  #   Returns a new CArray of `data_type` whose cell at outer
  #   address `addr` is the block's result on the kernel at that
  #   address.
  #   @param data_type [Symbol, Integer] result `data_type`.
  #   @param options [Hash] passed to `prepare_output`.
  #   @yieldparam kernel [CArray]
  #   @yieldreturn [Object]
  #   @return [CArray]
  def convert (data_type, options={})
    out = prepare_output(data_type, options)
    out.map_addr!{ |addr|
      blk = kernel_at_addr(addr)
      yield(blk.clone)
    }
    return out
  end

  # @overload each { |kernel| ... }
  #   Yields each kernel of `self`. Kernels are cloned before
  #   yielding so the block may retain references safely.
  #   @yieldparam kernel [CArray]
  #   @return [Object] the block's last return value.
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

  # @overload each_with_addr { |kernel, addr| ... }
  #   Yields each kernel paired with its outer flat address.
  #   @yieldparam kernel [CArray]
  #   @yieldparam addr [Integer]
  #   @return [Object]
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

  # @overload each_with_index { |kernel, idx| ... }
  #   Yields each kernel paired with its outer N-D index.
  #   @yieldparam kernel [CArray]
  #   @yieldparam idx [Array<Integer>]
  #   @return [Object]
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

  # @overload inject { |acc, kernel| ... }
  #   Reduces the kernels seeded with the first kernel.
  #   @yieldparam acc [Object]
  #   @yieldparam kernel [CArray]
  #   @return [Object]
  # @overload inject(init) { |acc, kernel| ... }
  #   Reduces the kernels seeded with `init`.
  #   @param init [Object]
  #   @return [Object]
  #   @raise [RuntimeError] on more than one positional argument.
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

end
