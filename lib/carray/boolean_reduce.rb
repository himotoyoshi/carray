# Boolean folds all / any / none gain a `skip_masked:` keyword.
#
#   skip_masked: true  (default) -- available-case (skipna): masked cells are
#                                    ignored, the result is always true/false.
#                                    This is the existing behavior; every other
#                                    keyword (axis:, keep_axis:, ...) forwards
#                                    unchanged to the C reduction.
#   skip_masked: false           -- three-valued (Kleene) fold: the result is
#                                    UNDEF when a masked cell could change it.
#                                    OR is undetermined without a known true;
#                                    AND without a known false.  Matches the
#                                    element-wise `|` / `&` Kleene semantics as
#                                    an n-ary fold (|=max, &=min over
#                                    false < unknown < true).
#
# The Kleene fold composes from count(true) / count(false) / count_masked, so
# there is no dedicated kernel; the C reductions keep the skipna semantics
# under the `__*_skipna__` aliases.

class CArray

  alias_method :__any_skipna__,  :any
  alias_method :__all_skipna__,  :all
  alias_method :__none_skipna__, :none
  private :__any_skipna__, :__all_skipna__, :__none_skipna__

  # Whether any cell is true.
  #
  # With `skip_masked: true` (the default) masked cells are simply ignored and
  # the result is always `true` / `false`.  With `skip_masked: false` the fold
  # is three-valued: the result is `UNDEF` when a masked cell could change it,
  # matching the element-wise Kleene semantics of `|` / `&`.
  #
  # @param skip_masked [Boolean] ignore masked cells, or fold them three-valued.
  # @param opts [Hash] forwarded to the underlying reduction (`axis:`,
  #   `keep_axis:`, ...).
  # @return [Boolean, CArray] a scalar, or an array when an axis is given.
  def any (skip_masked: true, **opts)
    return __any_skipna__(**opts) if skip_masked
    __kleene_fold(:any, opts)
  end

  # Whether every cell is true.
  #
  # With `skip_masked: true` (the default) masked cells are simply ignored and
  # the result is always `true` / `false`.  With `skip_masked: false` the fold
  # is three-valued: the result is `UNDEF` when a masked cell could change it,
  # matching the element-wise Kleene semantics of `|` / `&`.
  #
  # @param skip_masked [Boolean] ignore masked cells, or fold them three-valued.
  # @param opts [Hash] forwarded to the underlying reduction (`axis:`,
  #   `keep_axis:`, ...).
  # @return [Boolean, CArray] a scalar, or an array when an axis is given.
  def all (skip_masked: true, **opts)
    return __all_skipna__(**opts) if skip_masked
    __kleene_fold(:all, opts)
  end

  # Whether no cell is true.
  #
  # With `skip_masked: true` (the default) masked cells are simply ignored and
  # the result is always `true` / `false`.  With `skip_masked: false` the fold
  # is three-valued: the result is `UNDEF` when a masked cell could change it,
  # matching the element-wise Kleene semantics of `|` / `&`.
  #
  # @param skip_masked [Boolean] ignore masked cells, or fold them three-valued.
  # @param opts [Hash] forwarded to the underlying reduction (`axis:`,
  #   `keep_axis:`, ...).
  # @return [Boolean, CArray] a scalar, or an array when an axis is given.
  def none (skip_masked: true, **opts)
    return __none_skipna__(**opts) if skip_masked
    # none = not any (Kleene): not(true)=false, not(false)=true, not(UNDEF)=UNDEF
    r = __kleene_fold(:any, opts)
    r.is_a?(CArray) ? r.not : (r.equal?(UNDEF) ? UNDEF : !r)
  end

  private

  # Three-valued fold via counts.  `kind` is :any (OR) or :all (AND).
  # `opts` carries axis: / keep_axis: (same surface as the skipna reduction).
  def __kleene_fold (kind, opts)
    axis = opts[:axis]
    if axis.nil?
      if kind == :any
        return true  if count(true)  > 0     # a known TRUE settles OR
      else
        return false if count(false) > 0     # a known FALSE settles AND
      end
      return UNDEF if count_masked > 0        # undetermined
      return( kind == :any ? false : true )
    end

    keep = opts[:keep_axis]
    cnt_kw = keep ? { axis: axis, keep_axis: keep } : { axis: axis }
    ck = ( kind == :any ) ? count(true, **cnt_kw) : count(false, **cnt_kw)
    cm = count_masked(axis: axis)               # count_masked has no keep_axis
    cm = cm.reshape(*ck.shape) unless cm.shape == ck.shape

    # A cell is undetermined only where it is masked AND the known side does
    # not settle it (ck counts the settling value: true for OR, false for AND).
    # Masking only those cells avoids leaving an all-zero mask behind.
    out = CArray.boolean(*ck.shape)
    out[] = ( kind == :any ) ? 0 : 1            # OR default false / AND default true
    out[ck.eq(0) & (cm > 0)] = UNDEF             # genuinely undetermined
    out[ck > 0] = ( kind == :any ) ? 1 : 0       # known side dominates
    out
  end

end
