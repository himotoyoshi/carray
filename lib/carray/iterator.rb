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

  # The required reduction surface, modelled on the two reference members
  # CASlabIterator and CACategoricalIterator (the surface they both provide).
  # Declared abstract so a later member
  # (window / block / group) that leaves one unimplemented fails loudly here
  # rather than reading as "no such method" -- that gap is the member's to close.
  # A member that genuinely cannot provide one overrides it to raise with its
  # own reason.
  [
    :sum, :prod, :mean, :min, :max, :variance, :stddev, :all, :any,   # tier 1
    :variancep, :stddevp, :minmax,                                    # tier 2
    :min_index, :max_index, :min_addr, :max_addr,                     # position
    :wsum, :wmean,                                                    # weighted
    :median, :percentile, :quantile,                                 # tier 3
    :count, :count_not_masked, :count_masked, :elements,             # count family
    :each, :reduce,                                                   # generic iterate
  ].each do |name|
    define_method(name) do |*, **, &_blk|
      raise NotImplementedError, "#{self.class} must implement ##{name}"
    end
  end

  # Recommended (should) surface -- template methods.  These are well-defined
  # for some members and structurally impossible for others, so they are not
  # required: `map` is a per-piece element-wise transform scattered back to the
  # source, `sort_addr` is a per-piece sort returning source flat addresses, and
  # the segment scans (cumsum / cumprod / cummax / cummin / cumcount) write a
  # per-cell running statistic of each piece.  A member implements each when it
  # is well-defined and overrides it to raise with a reason when it is not.  The
  # scans belong here for the same reason as map: a running per-cell value is
  # single-valued only when each cell belongs to exactly one piece, so the
  # partition members (slab / block / categorical / group) provide them, while
  # CAWindowIterator's overlapping padded windows put a cell in many windows --
  # no single running value -- and it raises, exactly as it does for map /
  # sort_addr.  Un-overridden each is simply unavailable, not a contract
  # violation.  min_addr / max_addr stay required: a single winner address is
  # well-defined even for an overlapping window.
  [:map, :sort_addr,
   :cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |name|
    define_method(name) do |*, **, &_blk|
      raise NotImplementedError, "#{self.class} does not provide ##{name} (optional)"
    end
  end

end
