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

  # reshape / flatten / transpose! are defined in C
  # (ext/ca_obj_refer.c and ext/ca_obj_transpose.c).  The bare size-1
  # insertion primitive is `__insert_axis_size1__` (C); `insert_axis` below
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
  #   Each inserted axis takes one of three forms, chosen by its
  #   `repeat` value: `1` (or `nil`) for a plain size-1 axis, an
  #   Integer `N > 1` for a read-only bound repeat view, or `:*` for
  #   an unbound repeat that binds on assignment. `repeat` is either
  #   a single value applied to every inserted axis, or an Array
  #   giving one value per position.
  #
  #   The everyday way to add an axis is the `:_` / `:*` indexer
  #   when the shape is known at the call site; `insert_axis` is for
  #   library code that builds the axis list programmatically.
  #
  #   @param positions [Array<Integer>] source-frame positions of the
  #     new axes.
  #   @param repeat [Integer, Symbol, Array, nil] repeat spec applied
  #     to each inserted axis.
  #   @return [CArray] view with the new axes inserted.
  #   @example
  #     a = CArray.int32(3, 4).seq
  #     a.insert_axis(0)                       # shape (1, 3, 4)
  #     a.insert_axis(1, repeat: 5)            # shape (3, 5, 4)
  #     a.insert_axis(0, 1, repeat: [:*, 3])   # mixed unbound + bound
  def insert_axis (*positions, repeat: nil)
    flat = positions.flatten
    if flat.empty?
      raise ArgumentError, "insert_axis: at least one position is required"
    end

    # No repeat: -> plain size-1 insertion.  The source-frame C primitive
    # handles normalization, range check and multiplicity directly.
    return __insert_axis_size1__(*flat) if repeat.nil?

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

    # Validate each value.  A positive Integer or :* only; nil is not a
    # valid per-axis repeat.
    reps.each do |r|
      case r
      when Integer
        raise ArgumentError, "insert_axis: repeat count must be >= 1" if r < 1
      when :*
        # ok
      else
        raise ArgumentError,
          "insert_axis: repeat must be a positive Integer or :*, got #{r.inspect}"
      end
    end

    # Final output layout: stable order by (gap, argument index) keeps
    # same-gap axes in argument order; the k-th inserted axis lands at output
    # position gap + k.  This output position is only used to drive the
    # output-shaped view constructors (broadcast_to / unbound_repeat); the
    # actual insertion always goes through the source-frame primitive below.
    order = (0...flat.length).sort_by { |i| [gaps[i], i] }
    final = {}
    order.each_with_index { |i, k| final[i] = gaps[i] + k }

    unbound_args  = order.select { |i| reps[i] == :* }
    concrete_args = order.reject { |i| reps[i] == :* }   # in output order

    # Stage 1: insert the concrete (size-1 / bound) axes by their source
    # gaps, then grow the bound ones with broadcast_to.
    inter = self
    unless concrete_args.empty?
      inter = __insert_axis_size1__(*concrete_args.map { |i| gaps[i] })
      if concrete_args.any? { |i| reps[i].is_a?(Integer) && reps[i] > 1 }
        shp = inter.shape
        concrete_args.each do |i|
          r = reps[i]
          next unless r.is_a?(Integer) && r > 1
          # intermediate position = final position minus unbound axes before it
          shp[final[i] - unbound_args.count { |u| final[u] < final[i] }] = r
        end
        inter = inter.broadcast_to(*shp)
      end
    end

    return inter if unbound_args.empty?

    # Stage 2: add the unbound axes over the final ndim (`:*` at unbound
    # positions, nil consumes one stage-1 axis in order).
    pattern = Array.new(ndim + flat.length, nil)
    unbound_args.each { |i| pattern[final[i]] = :* }
    inter.unbound_repeat(*pattern)
  end

  # @overload drop_axis
  #   Returns a view of `self` with every size-1 axis dropped.
  #   @return [CArray] view with reduced `ndim`.
  def drop_axis
    if ndim == 1
      return self[]
    else
      newdim = shape.reject{|x| x == 1 }
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
  def paste (offset, src)
    raise ArgumentError, "offset length must equal ndim" if offset.length != ndim
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

  # @overload clip(min, max = nil, fill_value = nil, lfill: nil, ufill: nil)
  #   Returns `self` with every element clamped to `[min, max]`.
  #
  #   Either bound may be `nil` for a one-sided clip; that side
  #   dispatches to the `pmax` / `pmin` binop kernels. When
  #   `fill_value` (or `lfill` / `ufill`) is given, out-of-range
  #   cells are replaced by the fill instead of clamped -- pass
  #   `UNDEF` to mask that end. `fill_value` is sugar for symmetric
  #   dual-fill; `lfill` / `ufill` override per side.
  #
  #   Boundary is strict `[min, max]`: values equal to a bound
  #   remain unchanged in both the clamped and filled variants.
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
  #   @raise [ArgumentError] when both `min` and `max` are `nil`.
  #   @example
  #     a.clip(0, 10)                          # strict clamp
  #     a.clip(0, 10, -1)                      # both ends -> -1
  #     a.clip(0, 10, lfill: UNDEF, ufill: 99) # below masks
  def clip(min, max=nil, fill_value=nil, lfill: nil, ufill: nil)
    if min.nil? && max.nil?
      raise ArgumentError, "clip: at least one of (min, max) must be given"
    end

    # `fill_value` as a single argument is sugar applied to both ends; kwargs override.
    lfill = fill_value if lfill.nil?
    ufill = fill_value if ufill.nil?

    if lfill.nil? && ufill.nil?
      return __clip_ki__(min, max) if !min.nil? && !max.nil?
      return pmax(min) if max.nil?
      return pmin(max)
    end

    out = self.copy
    out[:lt, min] = lfill unless min.nil? || lfill.nil?
    out[:gt, max] = ufill unless max.nil? || ufill.nil?
    out
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
