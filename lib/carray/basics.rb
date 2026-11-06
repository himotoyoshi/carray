# Frequently-used CArray convenience methods kept eager-loaded.
#
# Rationale: a method lands here NOT because of its topic / domain (those
# have their own files such as compose.rb / math.rb / datetime.rb, many of
# them autoloaded) but because it is reached often enough that the
# lazy-autoload indirection is not worth it.  These methods are NOT
# load-bearing -- the core works without them; that distinguishes this file
# from carray/runtime.rb (which holds the support the core depends on).
#
# Keep this file small and obvious.  If a method is domain-specific or only
# occasionally used, it belongs in its topic file (autoloaded when possible),
# not here.

class CArray

  # A Ruby Array has no data type of its own, so it does not stand in for a
  # CArray: each reading of it (an object array by to_ca, the receiver's
  # type, the type of its values) disagrees with another rule.  The caller
  # makes it a CArray of the type it means.  The example names types to
  # write rather than the receiver's, which would cut a Float down.
  def self.refuse_ruby_array (name, role, dt = nil)
    example = dt == CA_BOOLEAN ? "CA_BOOLEAN(ary)" : "CA_INT64(ary) or CA_FLOAT64(ary)"
    raise TypeError,
          "#{name}: a Ruby Array is not #{role}; make it a CArray of the " \
          "type you mean first, e.g. #{example}"
  end
  private_class_method :refuse_ruby_array


  # The order sort puts two object values in (ca_obj_order_cmp in C): a
  # Float NaN after every other value, NaN ties NaN, other pairs by `<=>`.
  # nil when `<=>` cannot order the pair; the caller says what refused.
  private_class_method def self.object_order_cmp (a, b)
    a_nan = a.is_a?(Float) && a.nan?
    b_nan = b.is_a?(Float) && b.nan?
    return (a_nan ? 1 : 0) - (b_nan ? 1 : 0) if a_nan || b_nan
    a <=> b
  end

  # reshape / flatten / transpose! are defined in C
  # (ext/ca_obj_refer.c and ext/ca_obj_transpose.c).  The bare size-1
  # insertion primitive is `insert_size_one_axes` (C); `insert_axis` below
  # is the user-facing method that owns the name and adds `repeat:`.

  # @overload insert_axis(*positions, repeat: nil)
  #   Returns a view of `self` with one or more new axes inserted,
  #   optionally repeating along them.
  #
  #   Each entry of `positions` names the source axis the new axis
  #   goes *before*. `ndim` (one past the last axis) appends at the
  #   end; negative positions count from the end. Repeating the same
  #   position inserts several axes before that axis, in argument
  #   order. Positions are in the *source* frame, so they do not
  #   shift as other axes are inserted (e.g. `insert_axis(0, 1, 2)`
  #   puts one axis before each of the first three source axes).
  #
  #   Each inserted axis takes one of two forms, chosen by its
  #   `repeat` value: `1` (or `nil`) for a plain size-1 axis, or an
  #   Integer `N > 1` for a read-only bound repeat view. `repeat` is
  #   either a single value applied to every inserted axis, or an
  #   Array giving one value per position.
  #
  #   The everyday way to add an axis is the `:_` indexer when the
  #   shape is known at the call site; `insert_axis` is for library
  #   code that builds the axis list programmatically.
  #
  #   @param positions [Array<Integer>] source-frame positions of the
  #     new axes.
  #   @param repeat [Integer, Array, nil] repeat spec applied to each
  #     inserted axis.
  #   @return [CArray] view with the new axes inserted.
  #   @example
  #     a = CArray.int32(3, 4).seq
  #     a.insert_axis(0)                       # shape (1, 3, 4)
  #     a.insert_axis(1, repeat: 5)            # shape (3, 5, 4)
  #     a.insert_axis(0, 1, repeat: [1, 3])    # size-1 then bound
  def insert_axis (*positions, repeat: nil)
    flat = positions.flatten
    if flat.empty?
      raise ArgumentError, "insert_axis: at least one position is required"
    end

    # No repeat: -> plain size-1 insertion.  The source-frame C primitive
    # handles normalization, range check and multiplicity directly.
    return insert_size_one_axes(*flat) if repeat.nil?

    # Source frame: each position names the source axis the new axis goes
    # before.  Gaps live in [0, ndim] (ndim = append at end); negatives count
    # from the end gap.  Duplicates are allowed (several axes before one
    # source axis), kept in argument order.
    gaps = flat.map { |p| CArray.normalize_axis(p, ndim + 1, "insert_axis") }

    # One repeat value per position, in argument order.
    reps =
      case repeat
      when Array
        unless repeat.length == flat.length
          raise ArgumentError,
            "insert_axis: repeat array length (#{repeat.length}) " \
            "must match number of positions (#{flat.length})"
        end
        repeat
      else
        Array.new(flat.length, repeat)
      end

    # Validate each value.  A positive Integer only; nil is not a valid
    # per-axis repeat.
    reps.each do |r|
      unless r.is_a?(Integer)
        raise ArgumentError,
          "insert_axis: repeat must be a positive Integer, got #{r.inspect}"
      end
      raise ArgumentError, "insert_axis: repeat count must be >= 1" if r < 1
    end

    # Final output layout: stable order by (gap, argument index) keeps
    # same-gap axes in argument order; the k-th inserted axis lands at output
    # position gap + k.  This output position only drives broadcast_to; the
    # insertion itself always goes through the source-frame primitive.
    order = (0...flat.length).sort_by { |i| [gaps[i], i] }
    final = {}
    order.each_with_index { |i, k| final[i] = gaps[i] + k }

    inter = insert_size_one_axes(*order.map { |i| gaps[i] })
    return inter unless order.any? { |i| reps[i] > 1 }

    shp = inter.shape
    order.each { |i| shp[final[i]] = reps[i] if reps[i] > 1 }
    inter.broadcast_to(*shp)
  end

  # @overload drop_axis
  #   Returns a view of `self` with every size-1 axis dropped.  When every
  #   axis has size 1, one axis of size 1 is kept.
  #   @return [CArray] view with reduced `ndim`.
  def drop_axis
    if ndim == 1
      return scalar? ? self : self[]
    else
      newdim = shape.reject{|x| x == 1 }
      newdim = [1] if newdim.empty?     # every axis has size 1: keep one
      return ( ndim != newdim.size ) ? reshape(*newdim) : self[]
    end
  end

  # @overload address
  #   Returns an int32 CArray of the same shape as `self` where each
  #   cell holds its row-major flat address.
  #   @return [CArray]
  def address
    return CArray.int32(*shape).seq!
  end

  # @overload false
  #   Returns a boolean CArray of the same shape as `self` filled
  #   with `false`.
  #   @return [CArray]
  def false ()
    return template(:boolean)
  end

  # @overload true
  #   Returns a boolean CArray of the same shape as `self` filled
  #   with `true`.
  #   @return [CArray]
  def true ()
    return template(:boolean) { 1 }
  end

  # A Face is clipped in its own terms: its comparisons decide which cells are
  # out of range (a time array reads its bounds as times, a record array
  # orders by its declared members, a Face that cannot be ordered refuses),
  # and its store writes the bound or the fill value into them.
  private def face_clip (min, max, fill_value, lfill, ufill)
    lfill = fill_value if lfill.nil?
    ufill = fill_value if ufill.nil?
    out = copy
    # Whatever is written must fit: a finer time, a wider fixed string.
    [min, max, lfill, ufill].each { |v|
      out, = branches_in_common(out, v) unless v.nil? || UNDEF.equal?(v)
    }
    out[self < min] = lfill.nil? ? min : lfill unless min.nil?
    out[self > max] = ufill.nil? ? max : ufill unless max.nil?
    out
  end

  # An array of +shape+ of the same kind as self: its data type and cell
  # width, or its Face over a zero storage.  Nothing is written into it, so
  # it can be built for a read-only Face too.
  # Whether a cell can be given a value it has not seen.  Not a CAConstString,
  # whose strings share a buffer, or a CACategorical, whose codes index a
  # vocabulary.  A view that is read-only can still hold them: it is only
  # that view that cannot be written.
  private def holds_new_values? = true

  private def blank_like (shape)
    storage = face_storage
    out = CArray.new(storage.data_type, shape, bytes: storage.bytes)
    face? ? out.face_lift(self) : out
  end

  # Sub-region copy (paste / crop), the old C `ca_paste` / `ca_clip` pair.
  # `clip` is reserved for value clamping (clamp to a min/max range), so
  # the read-out side is `crop`.  Kept together as a pair (crop is rare, but paste is reached
  # often -- concatenate / mosaic / resize / bit_string all use it).  Both
  # accept negative offsets.

  # @overload paste(offset, src)
  #   Sets `self` at `offset` by copying `src`. Out-of-bounds cells
  #   (`src` extending past `self`'s edge or before its origin) are
  #   silently dropped via CAWindow's interior-only PUT scatter.
  #   @param offset [Array<Integer>] starting indices, length equal
  #     to `self.ndim`.
  #   @param src [CArray] source array.
  #   @return [self]
  #   @raise [ArgumentError] when `offset.length != self.ndim`.
  #   @raise [FrozenError] when `self` is frozen.
  def paste (offset, src)
    CArray.send(:refuse_ruby_array, "paste", "an array to paste") if src.is_a?(Array)
    # The write goes through a window view, which is not frozen itself:
    # refuse a frozen self here, as a write into it directly is refused.
    if frozen?
      raise FrozenError.new("can't modify frozen #{self.class}: #{inspect}", receiver: self)
    end
    raise ArgumentError, "offset length must equal ndim" if offset.length != ndim
    # A zero-length source covers no cell, so there is nothing to write --
    # and the empty range it would ask for is not a window CAWindow can
    # build.  This is what lets concatenate / mosaic take an empty piece.
    return self if src.elements.zero?
    ranges = offset.each_with_index.map { |o, i| o...(o + src.shape[i]) }
    self.window(*ranges)[] = src
    self
  end

  # @overload crop(offset, dst)
  #   Reads a `dst.shape`-sized region from `self` starting at
  #   `offset` into `dst`. Cells whose read position falls outside
  #   `self` leave the corresponding `dst` cells untouched.
  #   @param offset [Array<Integer>] source starting indices, length
  #     equal to `self.ndim`.
  #   @param dst [CArray] destination array; mutated in place.
  #   @return [CArray] `dst`.
  #   @raise [ArgumentError] when `offset.length != self.ndim`.
  def crop (offset, dst)
    raise ArgumentError, "offset length must equal ndim" if offset.length != ndim
    src_ranges = []
    dst_ranges = []
    ndim.times do |i|
      s_lo = [offset[i], 0].max
      s_hi = [offset[i] + dst.shape[i], shape[i]].min
      return dst if s_lo >= s_hi
      src_ranges << (s_lo...s_hi)
      dst_ranges << ((s_lo - offset[i])...(s_hi - offset[i]))
    end
    dst[*dst_ranges] = self[*src_ranges]
    dst
  end

  # @overload lookup(table, fill_value = nil, lfill: nil, ufill: nil)
  #   Returns values gathered from `table` at the indices given by
  #   `self`. Equivalent to `table.project(self, lfill, ufill)` with
  #   the receiver / first argument swapped so the index reads as
  #   the subject. `fill_value` is sugar for symmetric dual-fill;
  #   `lfill` / `ufill` override per side (`UNDEF` or `nil` masks
  #   that end), following the `project` vocabulary.
  #   @param table [CArray] value table indexed by `self`.
  #   @param fill_value [Object, nil] symmetric fill for below- and
  #     above-range indices.
  #   @param lfill [Object, nil] override for below-range fill.
  #   @param ufill [Object, nil] override for above-range fill.
  #   @return [CArray] gathered values with the shape of `self`.
  def lookup(table, fill_value=nil, lfill: nil, ufill: nil)
    lfill = fill_value if lfill.nil?
    ufill = fill_value if ufill.nil?
    table.project(self, lfill, ufill)
  end

  # @overload <=>(other)
  #   Returns an element-wise 3-way comparison: `+1` where
  #   `self > other`, `-1` where `self < other`, `0` where equal.
  #   Output `data_type` is `CA_INT8`.
  #   @param other [CArray, Numeric] operand to compare against.
  #   @return [CArray]
  def <=> (other)
    (self > other).as_int8 - (self < other).as_int8
  end

  alias cmp <=>

  # @!group Elementwise math

  # Returns `[quotient, remainder]` element-wise.
  #
  # The quotient is floored toward -inf, so `q * other + r == self` holds
  # for every sign combination -- the pair Ruby's `Integer#divmod` and
  # `Float#divmod` return.  For integers that is `self / other` unchanged;
  # for floats `/` is true division, so the quotient is floored here.
  #
  # @param other [CArray, Numeric] divisor.
  # @return [Array<CArray>] the floored quotient and the remainder.
  # @raise [ArgumentError] for complex arrays, which have no ordering to
  #   floor toward.
  # @example
  #   CA_INT32([-7]).divmod(3)     # => [-3, 2]
  #   CA_DOUBLE([-7.0]).divmod(3.0) # => [-3.0, 2.0]
  def divmod(other)
    if complex?
      raise ArgumentError, "divmod is not defined for complex arrays"
    end
    q = self / other
    q = q.floor unless q.integer?
    [q, self % other]
  end

  # @!endgroup

  # An Integer shift count on an integer array means what it means to
  # Integer#<< and #>>: negative shifts the other way, and a count past the
  # width shifts every bit out.  The kernels do that for a count of the
  # array's own type; this brings a count the type cannot hold -- -1 for a
  # uint8 array, 300 for an int8 one -- to one it can.
  module IntegerShiftCount
    UNSIGNED = [CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].freeze

    def << (other)
      return super unless other.is_a?(Integer) && integer? && ! face?
      w = bytes * 8
      return self >> -other if other < 0 && UNSIGNED.include?(data_type)
      super(other.clamp(-w, w))
    end

    def >> (other)
      return super unless other.is_a?(Integer) && integer? && ! face?
      w = bytes * 8
      return self << -other if other < 0 && UNSIGNED.include?(data_type)
      super(other.clamp(-w, w))
    end

    def bit_lshift! (other)
      return super unless other.is_a?(Integer) && integer? && ! face?
      w = bytes * 8
      return bit_rshift!(-other) if other < 0 && UNSIGNED.include?(data_type)
      super(other.clamp(-w, w))
    end

    def bit_rshift! (other)
      return super unless other.is_a?(Integer) && integer? && ! face?
      w = bytes * 8
      return bit_lshift!(-other) if other < 0 && UNSIGNED.include?(data_type)
      super(other.clamp(-w, w))
    end
  end

  # An Integer exponent on an integer array is a count, not a value of the
  # array's type: `a ** 1000` multiplies 1000 times and keeps the answer
  # modulo 2 ** bits, as the kernels do for an exponent of the array's own
  # type.  An exponent the type can not hold is brought to one it can that
  # gives the same answer: x ** p modulo 2 ** n repeats with period
  # 2 ** (n - 2) once p is at least n (an even x is then 0), and a
  # negative power is decided by x and the parity of p alone.  An integer
  # CScalar exponent is read as its Integer.
  module IntegerPowerCount
    def ** (other)
      if unfit_scalar_base_of?(other)
        return other.send(:power_with_unfit_base, self[0])
      end
      count = integer_power_count(other)
      return unsigned_reciprocal_power if unsigned_negative_count?(count)
      return super(count)
    end

    def pow! (other)
      count = integer_power_count(other)
      if unsigned_negative_count?(count)
        self[] = unsigned_reciprocal_power
        return self
      end
      return super(count)
    end

    private

    def integer_power_count (other)
      return other unless integer? && ! face?
      if other.is_a?(CScalar) && other.integer? && ! other.face? && ! other.any_masked?
        other = other[0]
      end
      return other unless other.is_a?(Integer)
      bits = bytes * 8
      if IntegerShiftCount::UNSIGNED.include?(data_type)
        return other if other < 0          # unsigned_reciprocal_power
        lo, hi = 0, 2**63 - 1              # the kernels read the count as int64
      else
        lo, hi = -2**(bits - 1), 2**(bits - 1) - 1
      end
      return other if other.between?(lo, hi)
      return ( other.even? ? -2 : -1 ) if other < 0
      return bits + (other - bits) % 2**(bits - 2)
    end

    # An integer CScalar on the left whose value the array's type can not
    # hold is taken at its value, as an Integer is.
    def unfit_scalar_base_of? (other)
      return false unless is_a?(CScalar) && integer? && ! face? && ! any_masked?
      return false unless other.is_a?(CArray) && ! other.is_a?(CScalar) &&
                          other.integer? && ! other.face?
      bits = other.bytes * 8
      lo, hi = IntegerShiftCount::UNSIGNED.include?(other.data_type) ?
               [0, 2**bits - 1] : [-2**(bits - 1), 2**(bits - 1) - 1]
      return ! self[0].between?(lo, hi)
    end

    # base ** self for an Integer base this array's type can not hold.  A
    # cell with an exponent of 0 or more gets the base cut to the type
    # (modulo 2 ** bits): b and b' equal modulo 2 ** n give b ** p and
    # b' ** p equal modulo 2 ** n.  A negative exponent is 1 / base ** -p
    # in integer division, which the base decides itself and the cut base
    # would not (256 is 0 as uint8, 257 is 1): the base is at least 2 in
    # size, so the cell is 0.
    def power_with_unfit_base (base)
      bits = bytes * 8
      cut = base % 2**bits
      if IntegerShiftCount::UNSIGNED.include?(data_type)
        return cut ** self
      end
      cut -= 2**bits if cut >= 2**(bits - 1)
      negative = self.lt(0)
      power = cut ** negative.then_else(0, self)
      return negative.then_else(0, power)
    end

    def unsigned_negative_count? (count)
      return count.is_a?(Integer) && count < 0 &&
             IntegerShiftCount::UNSIGNED.include?(data_type) && ! face?
    end

    # x ** -p is 1 / x ** p in integer division, which x decides alone, as
    # on a signed array: 0 has no reciprocal, 1 stays 1, anything larger
    # is 0.  The kernels of an unsigned array take no negative exponent.
    def unsigned_reciprocal_power
      raise ZeroDivisionError, "divided by 0" if self.eq(0).any
      # coerce: x ** p keeps the type of x, as the kernels give it
      return self.eq(1).to_type(data_type)
    end
  end

  # Prepended by carray/lazy, after it has wrapped << and >>: prepended
  # here, the method lazy aliases as the eager form would be this one.

  # @overload clip(min, max = nil, fill_value = nil, lfill: nil, ufill: nil)
  #   Returns `self` with every element clamped to `[min, max]`.
  #
  #   Either bound may be `nil` for a one-sided clip. When
  #   `fill_value` (or `lfill` / `ufill`) is given, out-of-range
  #   cells are replaced by the fill instead of clamped -- pass
  #   `UNDEF` to mask that end. `fill_value` is sugar for symmetric
  #   dual-fill; `lfill` / `ufill` override per side, and a side
  #   given no fill is still clamped.
  #
  #   `min` may not exceed `max` (in any cell, when a bound is an
  #   array); equal bounds give every unmasked cell that value.
  #   A NaN cell of `self` stays NaN, one-sided or two-sided (unlike
  #   `pmax` / `pmin`, which answer the other operand for it).
  #   A NaN in a bound array leaves that cell unbounded on that side,
  #   as `nil` does for the whole side.  A bound is never UNDEF or
  #   masked: a missing bound is not read as either, so fill it first.
  #
  #   On an integer array an Integer bound the type can not hold is taken
  #   by value: a lower bound below the type or an upper bound above it
  #   bounds nothing (`CA_UINT8([1, 200]).clip(0, 1000)` is `[1, 200]`);
  #   a lower bound above the type or an upper bound below it would put
  #   every cell out of the type, and raises `RangeError`.
  #
  #   Boundary is strict `[min, max]`: values equal to a bound
  #   remain unchanged in both the clamped and filled variants.  A NaN
  #   is in neither range and stays NaN.
  #
  #   @param min [Numeric, nil] lower bound; `nil` for one-sided
  #     clip above.
  #   @param max [Numeric, nil] upper bound; `nil` for one-sided
  #     clip below.
  #   @param fill_value [Object, nil] symmetric fill for
  #     out-of-range cells.
  #   @param lfill [Object, nil] override below-range fill.
  #   @param ufill [Object, nil] override above-range fill.
  #   @return [CArray] new CArray with clamped or filled values.
  #   @raise [ArgumentError] when both `min` and `max` are `nil`,
  #     when either is `UNDEF` or has a masked cell, or when `min`
  #     exceeds `max`.
  #   @example
  #     a.clip(0, 10)                          # strict clamp
  #     a.clip(0, 10, -1)                      # both ends -> -1
  #     a.clip(0, 10, lfill: UNDEF, ufill: 99) # below masks
  def clip(min, max=nil, fill_value=nil, lfill: nil, ufill: nil)
    if min.nil? && max.nil?
      raise ArgumentError, "clip: at least one of (min, max) must be given"
    end
    [min, max].each do |bound|
      undefined = UNDEF.equal?(bound) ||
                  (bound.is_a?(CArray) && bound.any_masked?) ||
                  (bound.is_a?(Array) && bound.flatten.any? { |v| UNDEF.equal?(v) })
      next unless undefined
      raise ArgumentError, "clip: a bound can not be UNDEF or masked " \
                           "(fill the bound first; a NaN bound leaves its cell " \
                           "unbounded, and UNDEF as the fill masks the cells out of range)"
    end
    return face_clip(min, max, fill_value, lfill, ufill) if face?
    if !min.nil? && !max.nil?
      # A Ruby Array bound is refused by the clamp below (the operand rule
      # of pmax / pmin), so it is not compared here.
      reversed = if min.is_a?(CArray) then min.gt(max).any
                 elsif max.is_a?(CArray) then max.lt(min).any
                 elsif min.is_a?(Array) || max.is_a?(Array) then false
                 else min > max
                 end
      if reversed
        raise ArgumentError, "clip: min must be less than or equal to max"
      end
    end

    # `fill_value` as a single argument is sugar applied to both ends; kwargs override.
    lfill = fill_value if lfill.nil?
    ufill = fill_value if ufill.nil?

    if lfill.nil? && ufill.nil?
      return clamp_between(min, max) if !min.nil? && !max.nil?
      return clamp_below(min) if max.nil?
      return clamp_above(max)
    end

    # A side without a fill still clamps.
    out = self.copy
    out = out.clamp_below(min) if !min.nil? && lfill.nil?
    out = out.clamp_above(max) if !max.nil? && ufill.nil?
    out[self.lt(min)] = lfill unless min.nil? || lfill.nil?
    out[self.gt(max)] = ufill unless max.nil? || ufill.nil?
    out
  end

  # A one-sided clip of a float array passes a NaN cell through, as the
  # two-sided one does: the open side is a NaN bound, which leaves it
  # unbounded.  pmax / pmin would answer the bound for a NaN cell.
  protected def clamp_below (min)
    float? ? clamp_between(min, Float::NAN) : pmax(min)
  end

  protected def clamp_above (max)
    float? ? clamp_between(Float::NAN, max) : pmin(max)
  end

  # `contains` was retired in favour of {#is_in} (value-hash membership).
  # `a.contains(v1, v2)` -> `a.is_in([v1, v2])`;
  # `a.contains(v1, v2, axis: k)` -> `a.is_in([v1, v2]).any(axis: k)`.
  # See carray/methods/is_in.rb. Note is_in collapses NaN (a NaN cell is in a
  # set containing NaN), whereas contains (self.eq) never matched NaN.

  # `windows` (the sliding-window iterator entry) lives in
  # carray/window_iterator.rb, autoloaded on first use.

  # ---------------------------------------------------------------------------
  # Sequence fill over a range (span / span!) and a linear interval
  # (scale / scale!).
  # ---------------------------------------------------------------------------

  # @overload span!(range)
  #   Sets `self` to a linear sequence over `range`, with the step
  #   chosen so that `range.end` (or `range.end` when the range is
  #   exclusive-end, treated as the limit not reached) determines the
  #   endpoint. Concretely:
  #
  #   - inclusive range `a..b`: `self[0] == a`, `self[-1] == b`,
  #     intermediate values are evenly spaced.
  #   - exclusive range `a...b`: `self[0] == a`, `self[-1] == a + (N-1)
  #     * (b-a)/N` (endpoint `b` is not reached).
  #
  #   Only **float** arrays are supported. Integer arrays raise —
  #   "N evenly-spaced integers" is not a well-defined concept; the
  #   error message shows the two idioms that cover the two distinct
  #   integer use cases:
  #
  #   - (A) N points with both endpoints hitting `a` and `b` exactly
  #     (linspace-like): use the manual integer form
  #     `CArray.int32(N).seq * (b - a) / (N - 1) + a`, or sample as
  #     float then cast: `CArray.float64(N).span(a.to_f..b.to_f).int32`.
  #   - (B) N labels distributed uniformly over the value range so
  #     each of the `(b - a + 1)` values appears approximately the
  #     same number of times (bucket distribution): use
  #     `CArray.int32(N).seq * (b - a + 1) / N + a`.
  #
  #   @param range [Range<Numeric>] value range to span.
  #   @return [self]
  #   @raise [ArgumentError] when `self` is not a float array.
  def span! (range)
    unless float?
      raise ArgumentError,
            "span!: integer arrays are ambiguous — 'N evenly-spaced " \
            "integers' has two distinct meanings. Pick the one you want:\n" \
            "  (A) N points hitting both endpoints exactly (linspace-like):\n" \
            "      CArray.int32(N).seq * (b - a) / (N - 1) + a\n" \
            "      or  CArray.float64(N).span(a.to_f..b.to_f).int32\n" \
            "  (B) N labels distributed uniformly over range values:\n" \
            "      CArray.int32(N).seq * (b - a + 1) / N + a"
    end
    first = range.begin.to_r
    last  = range.end.to_r
    step = range.exclude_end? ? (last-first)/elements : (last-first)/(elements-1)
    seq!(first, step)
    return self
  end

  # @overload span(range)
  #   Returns a fresh CArray shaped like `self` filled with the
  #   linear sequence produced by {#span!}. Float arrays only.
  #   @param range [Range<Numeric>] value range to span.
  #   @return [CArray]
  #   @raise [ArgumentError] when `self` is not a float array.
  def span (range)
    return template.span!(range)
  end

  # @overload scale!(xa, xb)
  #   Sets `self` to `elements` evenly spaced float64 values from
  #   `xa` to `xb` inclusive.
  #   @param xa [Numeric] first value.
  #   @param xb [Numeric] last value.
  #   @return [self]
  def scale! (xa, xb)
    xa = xa.to_f
    xb = xb.to_f
    seq!(xa, (xb-xa)/(elements-1))
  end

  # @overload scale(xa, xb)
  #   Returns a fresh CArray shaped like `self` holding `elements`
  #   evenly spaced values from `xa` to `xb` inclusive.
  #   @param xa [Numeric] first value.
  #   @param xb [Numeric] last value.
  #   @return [CArray]
  def scale (xa, xb)
    template.scale!(xa, xb)
  end

end

# ---------------------------------------------------------------------------
# Container -> CArray coercion (relocated from former basic.rb)
# ---------------------------------------------------------------------------

class Array

  # @overload to_ca(writable: false)
  #   Returns `self` coerced into a `CA_OBJECT` CArray of matching
  #   shape.
  #
  #   The result is a freshly built array that shares nothing with the
  #   receiver, so `writable: true` — a demand for a result whose writes
  #   reach the source — is refused.
  #   @return [CArray]
  #   @raise [RuntimeError] when `writable: true` is given.
  def to_ca(writable: false)
    if writable
      raise "#{self.class}#to_ca builds a new array; " \
            "it can't satisfy `writable: true'"
    end
    return CA_OBJECT(self)
  end
end

# Reopened to add {#to_ca}, so a Range can be handed to any CArray entry
# point that coerces its operand (`CArray.cast`, `wrap_readonly`, `meshgrid`).
class Range

  # @overload to_ca(writable: false)
  #   Returns the members of `self` as a 1-D `CA_OBJECT` CArray.
  #
  #   Enumeration follows Ruby, so a Float range raises (`TypeError`,
  #   not iterable) and an endless range raises (`RangeError`); use
  #   {CArray.linspace} or `span!` for a float axis. A descending
  #   integer range is the one departure: it counts down
  #   (`(3..0).to_ca` gives `[3, 2, 1, 0]`, not the empty array
  #   `(3..0).to_a` gives), so that it agrees with the cast form
  #   `CA_INT32(3..0)`.
  #
  #   As with {Array#to_ca} the result is newly built, so `writable: true`
  #   is refused.
  #
  #   @return [CArray]
  #   @raise [RuntimeError] when `writable: true` is given.
  def to_ca(writable: false)
    if writable
      raise "#{self.class}#to_ca builds a new array; " \
            "it can't satisfy `writable: true'"
    end
    first, last = self.begin, self.end
    if first.is_a?(Integer) and last.is_a?(Integer) and first > last
      return CA_OBJECT(self, 1)          # step 1: signed arange
    end
    return CA_OBJECT(self)
  end
end

# Reopened to add {#to_ca}, so a stepped sequence can be handed to any CArray
# entry point that coerces its operand.
class Enumerator::ArithmeticSequence

  # @overload to_ca(writable: false)
  #   Returns the members of `self` as a 1-D `CA_OBJECT` CArray, so that
  #   a strided axis can be written `(0..10).step(2)` or `(0.0..1.0).step(0.25)`.
  #
  #   An endless sequence is rejected up front: unlike an endless Range,
  #   which `RangeError`s, enumerating one runs forever. As with
  #   {Range#to_ca}, descending integer bounds count down rather than
  #   coming back empty.
  #
  #   As with {Array#to_ca} the result is newly built, so `writable: true`
  #   is refused.
  #
  #   @return [CArray]
  #   @raise [RangeError] when the sequence has no end.
  #   @raise [RuntimeError] when `writable: true` is given.
  def to_ca(writable: false)
    if writable
      raise "#{self.class}#to_ca builds a new array; " \
            "it can't satisfy `writable: true'"
    end
    first, last, by = self.begin, self.end, self.step
    if last.nil?
      raise RangeError, "cannot convert endless arithmetic sequence to an array"
    end
    if first.is_a?(Integer) and last.is_a?(Integer) and by > 0 and first > last
      return CA_OBJECT(Range.new(first, last, exclude_end?), by)
    end
    return CA_OBJECT(to_a)
  end
end

class CArray
  # map_slab / reduce_slab over a Face answer in that Face, as its other
  # reductions do: each block value is written into a blank of the Face
  # (which reads a CATime::Element, a string, a Face array ...) and handed
  # to the slab engine as the storage it became; the result is lifted back
  # at the end.  A Face that holds no new value has no blank to write into,
  # so its values are collected as the surface objects they are.  A
  # `data_type:` from the caller is the caller's, and passes through.
  module FaceSlabResult
    def map_slab (**kw, &block)
      return super unless face? && kw[:data_type].nil? && block
      return super(**kw, data_type: :object, &block) unless holds_new_values?
      out = super(**kw, **face_slab_type) { |slab|
        face_slab_storage(block.call(slab), slab.shape)
      }
      out.face_lift(self)
    end

    def reduce_slab (**kw, &block)
      return super unless face? && kw[:data_type].nil? && block
      return super(**kw, data_type: :object, &block) unless holds_new_values?
      fiber = kw.key?(:init)
      init  = kw.delete(:init)
      out = super(**kw, **face_slab_type) { |slab|
        value = if fiber
                  slab.to_a.flatten.inject(init) { |acc, e| block.call(acc, e) }
                else
                  block.call(slab)
                end
        face_slab_storage(value, [1])[0]
      }
      out.face_lift(self)
    end

    private

    # The engine's output type.  Fixlen storage is named by leaving it out: the
    # name alone has no width, and the source's is the one wanted.
    def face_slab_type
      storage = face_storage
      storage.data_type == CA_FIXLEN ? {} : { data_type: storage.data_type }
    end

    def face_slab_storage (value, shape)
      cell = blank_like(shape)
      cell[] = value
      cell.__send__(:face_storage)
    end
  end

  prepend FaceSlabResult
end
