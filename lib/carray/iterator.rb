# ----------------------------------------------------------------------------
#
#  CAIterator -- the form-only base of the iterator family.  It carries no
#  engine: each family member (CASlabIterator / CAWindowIterator /
#  CABlockIterator / CACategoricalIterator / CAGroupIterator) implements its own
#  fast engine.  The base declares two things: the shared form accessors over
#  the @ndim / @shape ivars, and the common reduction surface every member must
#  implement (surface uniformity is the value: "this is an iterator, so it must
#  answer these").
#
#  `shape` is canonical; `dim` is a legacy alias.  A member exposes what it
#  actually holds (source / reference / labels) and adds its own methods
#  (min_index / max_index / map / correlate / convolve / sort_addr / ...);
#  those are NOT part of the common contract because some members legitimately
#  omit them (a window has no map, a group has no within-piece min_index).
#
#  The 2.0 generic dispatch (calculate / filter / evaluate over a
#  kernel_at_addr slot) was retired in 3.0.
#
# ----------------------------------------------------------------------------

class CAIterator

  # No `include Enumerable`: the family surface is fully explicit per iterator,
  # so Enumerable's reduction-like names (to_a / min / sum / count / ...) do not
  # leak in and silently fold the pieces. A method outside the contract below
  # that a member does not define is a clean NoMethodError, not a wrong answer.

  attr_reader :ndim, :shape
  alias dim shape

  # The keywords a member passes on to a core reduction over its own axes.
  # The member sets `axis:`, so one from the caller is refused; the rest go
  # to the core, which checks them.
  # Whether a fill method carries values backward: :forward / :ffill carry
  # them forward, :backward / :bfill back. A member fills within its own
  # pieces by holding the nearest present value; :linear, which needs a
  # coordinate, is the core's alone.
  def self.hold_backward? (method) # :nodoc:
    case method
    when :forward, :ffill   then false
    when :backward, :bfill  then true
    else
      raise ArgumentError,
            "strip_mask: method must be :forward, :ffill, :backward or :bfill " \
            "within a piece (got #{method.inspect})"
    end
  end

  # A one-cell (1, 1) array of the kind `value` holds, for asking the core
  # what a reduction or scan of it answers in: its data type, cell width and,
  # for a Face, its Face.  A member that answers by a route of its own
  # (a fused kernel, a fold by offset) takes its output type from here, so
  # the route and the core cannot disagree.  A Face is a view of the values
  # themselves rather than a blank -- a Face cannot be allocated from its
  # surface data type alone, and a zeroed record is not a valid cell for every
  # one (a const string's record indexes a shared pool) -- so a Face with no
  # cell has nothing to ask with, and this is nil.
  def self.core_probe (value) # :nodoc:
    unless value.face?
      return CArray.new(value.data_type, [1, 1], bytes: value.bytes)
    end
    return nil if value.elements.zero?
    value.reshape(value.elements)[[0]].reshape(1, 1)
  end

  def self.reduce_keywords (op, kw) # :nodoc:
    if kw.key?(:axis)
      raise ArgumentError, "#{op}: unknown keyword: :axis (the iterator sets the axes)"
    end
    kw
  end

  # The required reduction surface, modelled on the two reference members
  # CASlabIterator and CACategoricalIterator (the surface they both provide).
  # Declared abstract so a later member
  # (window / block / group) that leaves one unimplemented fails loudly here
  # rather than reading as "no such method" -- that gap is the member's to close.
  # A member that genuinely cannot provide one overrides it to raise with its
  # own reason.
  # The methods below are declared here, so that the family surface is
  # documented in one place; each member generates its own implementation and
  # a member for which one is ill-defined overrides it to raise with a reason.
  # "Piece" is the unit a member iterates over: a slab, a window, a block, a
  # category, or a group.
  #
  # @!method sum
  #   Returns the sum of each piece.
  #   @return [CArray] one value per piece, shaped {#shape}.
  # @!method accumulate
  #   Returns the sum of each piece kept in the source's own `data_type`,
  #   wrapping at its width, where {#sum} answers in the type the core
  #   promotes to (`:float64` for integers).
  #   @return [CArray] one value per piece.
  # @!method prod
  #   Returns the product of each piece.
  #   @return [CArray] one value per piece.
  # @!method mean
  #   Returns the arithmetic mean of each piece.
  #   @return [CArray] one value per piece.
  # @!method min
  #   Returns the smallest value in each piece.
  #   @return [CArray] one value per piece.
  # @!method max
  #   Returns the largest value in each piece.
  #   @return [CArray] one value per piece.
  # @!method minmax
  #   Returns the smallest and largest value of each piece, found in one pass.
  #   @return [Array<CArray>] the pair `[min, max]`.
  # @!method variance
  #   Returns the sample variance (divisor `n - 1`) of each piece.
  #   @return [CArray] one value per piece.
  # @!method variancep
  #   Returns the population variance (divisor `n`) of each piece.
  #   @return [CArray] one value per piece.
  # @!method stddev
  #   Returns the sample standard deviation (divisor `n - 1`) of each piece.
  #   @return [CArray] one value per piece.
  # @!method stddevp
  #   Returns the population standard deviation (divisor `n`) of each piece.
  #   @return [CArray] one value per piece.
  # @!method all
  #   Returns whether every cell of each piece is true.
  #   @return [CArray] `:boolean`, one value per piece.
  # @!method any
  #   Returns whether any cell of each piece is true.
  #   @return [CArray] `:boolean`, one value per piece.
  # @!method min_index
  #   Returns the position of the smallest value **within** each piece.
  #   @return [CArray] one index per piece.
  # @!method max_index
  #   Returns the position of the largest value within each piece.
  #   @return [CArray] one index per piece.
  # @!method min_addr
  #   Returns the flat address **in the source** of the smallest value of each
  #   piece -- which source cell holds it, rather than where it sits inside the
  #   piece. Use it to read the same cell out of another source-shaped array.
  #   @return [CArray] one flat address per piece.
  # @!method max_addr
  #   Returns the flat address in the source of the largest value of each piece.
  #   @return [CArray] one flat address per piece.
  # @!method wsum(weights)
  #   Returns the weighted sum of each piece.
  #   @param weights [CArray] one weight per source cell, shaped like the source.
  #   @return [CArray] one value per piece.
  # @!method wmean(weights)
  #   Returns the weighted mean of each piece.
  #   @param weights [CArray] one weight per source cell, shaped like the source.
  #   @return [CArray] one value per piece.
  # @!method median
  #   Returns the median of each piece.
  #   @return [CArray] one value per piece.
  # @!method percentile(*pers)
  #   Returns the requested percentile(s) of each piece.
  #   @param pers [Array<Numeric>] percentile positions in `0..100`.
  #   @return [CArray, Array<CArray>] one array per requested position; a
  #     single position returns that array directly.
  # @!method quantile
  #   Returns the five-number summary of each piece,
  #   `[min, Q1, median, Q3, max]`.
  #   @return [Array<CArray>] five arrays, one per position.
  # @!method first
  #   Returns the first present value of each piece, in the piece's own
  #   order; a piece with no present value is UNDEF.
  #   @return [CArray] one value per piece, in the source's data type.
  # @!method last
  #   Returns the last present value of each piece; a piece with no present
  #   value is UNDEF.
  #   @return [CArray] one value per piece, in the source's data type.
  # @!method nunique
  #   Returns the number of distinct present values in each piece, as
  #   `CArray#nunique` counts them; a piece with none counts 0.
  #   @return [CArray] `:int64`, one count per piece.
  # @!method count(value = nil)
  #   Returns a count per piece: with no argument the cells that are not
  #   masked, with `UNDEF` the masked cells, and with any other value the
  #   cells equal to it.
  #   @param value [Object] value to match, or `UNDEF`.
  #   @return [CArray] one count per piece.
  # @!method count_not_masked
  #   Returns the number of cells of each piece that are not masked.
  #   @return [CArray] one count per piece.
  # @!method count_masked
  #   Returns the number of masked cells of each piece.
  #   @return [CArray] one count per piece.
  # @!method elements
  #   Returns the total number of cells in each piece, masked or not.
  #   @return [CArray] one count per piece.
  # @!method each
  #   Yields each piece in turn as a CArray.
  #   @yieldparam piece [CArray]
  #   @return [Enumerator, self] an Enumerator when no block is given.
  # @!method reduce(init = nil)
  #   Folds the pieces with a block, for a reduction the family does not name.
  #   Without `init` the first piece seeds the accumulator.
  #   @param init [Object] initial accumulator value.
  #   @yieldparam acc [Object] running accumulator.
  #   @yieldparam piece [CArray] next piece.
  #   @yieldreturn [Object] updated accumulator.
  #   @return [Object] the final accumulator.
  REQUIRED_SURFACE = [
    :sum, :accumulate, :prod, :mean, :min, :max,                      # tier 1
    :variance, :stddev, :all, :any,
    :variancep, :stddevp, :minmax,                                    # tier 2
    :min_index, :max_index, :min_addr, :max_addr,                     # position
    :wsum, :wmean,                                                    # weighted
    :median, :percentile, :quantile,                                 # tier 3
    :first, :last, :nunique,                                          # position / distinct
    :count, :count_not_masked, :count_masked, :elements,             # count family
    :each, :reduce,                                                   # generic iterate
  ].freeze

  REQUIRED_SURFACE.each do |name|
    define_method(name) do |*, **, &_blk|
      raise NotImplementedError, "#{self.class} must implement ##{name}"
    end
  end

  # Recommended (should) surface -- template methods.  These are well-defined
  # for some members and structurally impossible for others, so they are not
  # required: `map` is a per-piece element-wise transform scattered back to the
  # source, `sort_addr` is a per-piece sort returning source flat addresses, and
  # the segment scans (cumsum / cumprod / cummax / cummin / cumcount) write a
  # per-cell running statistic of each piece, and `lag` the value some steps
  # earlier in the same piece.  A member implements each when it
  # is well-defined and overrides it to raise with a reason when it is not.  The
  # scans belong here for the same reason as map: a running per-cell value is
  # single-valued only when each cell belongs to exactly one piece, so the
  # partition members (slab / block / categorical / group) provide them, while
  # CAWindowIterator's overlapping padded windows put a cell in many windows --
  # no single running value -- and it raises, exactly as it does for map /
  # sort_addr.  Un-overridden each is simply unavailable, not a contract
  # violation.  min_addr / max_addr stay required: a single winner address is
  # well-defined even for an overlapping window.
  # @!method map
  #   Returns a source-shaped array built by applying the block to each piece
  #   and scattering the result back into that piece's cells.
  #   @yieldparam piece [CArray]
  #   @yieldreturn [CArray, Numeric] replacement values for the piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap, where a
  #     cell would receive more than one value.
  # @!method sort_addr
  #   Returns a source-shaped array whose cells, read piece by piece, give the
  #   flat source addresses that put that piece in ascending order.
  #   @return [CArray] `:int64`, shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method cumsum
  #   Returns a source-shaped array of the running sum within each piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap, where a
  #     cell has no single running value.
  # @!method cumprod
  #   Returns a source-shaped array of the running product within each piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method cummax
  #   Returns a source-shaped array of the running maximum within each piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method cummin
  #   Returns a source-shaped array of the running minimum within each piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method cumcount
  #   Returns a source-shaped array of the running count of cells that are not
  #   masked within each piece.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method lag(n = 1)
  #   Returns a source-shaped array whose cell holds the value `n` steps
  #   earlier within the same piece, as `CArray#lag` does along an axis; a
  #   cell with no such value in its piece is UNDEF, so a lag never reaches
  #   across into another piece.
  #   @param n [Integer] steps back; a negative `n` looks ahead.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap, where a
  #     cell has no single position within a piece.
  # @!method strip_mask(method:)
  #   Returns a source-shaped array with each masked cell filled from its own
  #   piece, as `CArray#strip_mask(method:)` fills: `:forward` (`:ffill`)
  #   carries the last present value forward, `:backward` (`:bfill`) the next
  #   one back, never across into another piece.
  #   @param method [Symbol] `:forward`, `:ffill`, `:backward` or `:bfill`.
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap.
  # @!method order(descending: false, method: :ordinal, kind: :quick)
  #   Returns a source-shaped int64 array of each cell's rank among the cells
  #   of its piece, as `CArray#order` ranks them (`0` the smallest).
  #   @return [CArray] shaped like the source.
  #   @raise [NotImplementedError] for a member whose pieces overlap, where a
  #     cell has no single rank.
  [:map, :sort_addr, :order, :strip_mask,
   :cumsum, :cumprod, :cummax, :cummin, :cumcount, :lag].each do |name|
    define_method(name) do |*, **, &_blk|
      raise NotImplementedError, "#{self.class} does not provide ##{name} (optional)"
    end
  end

end
