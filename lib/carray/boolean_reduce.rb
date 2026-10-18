# Boolean folds all / any / none gain a `skip_masked:` keyword.
#
#   skip_masked: true  (default) -- available-case: masked cells are
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
# there is no dedicated kernel; the C reductions that skip masked cells stay
# reachable as the private `*_skipping_masked` aliases.

class CArray

  alias_method :any_skipping_masked,  :any
  alias_method :all_skipping_masked,  :all
  alias_method :none_skipping_masked, :none
  private :any_skipping_masked, :all_skipping_masked, :none_skipping_masked

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
    return any_skipping_masked(**opts) if skip_masked
    kleene_fold(:any, opts)
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
    return all_skipping_masked(**opts) if skip_masked
    kleene_fold(:all, opts)
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
    return none_skipping_masked(**opts) if skip_masked
    kleene_fold(:none, opts)
  end

  private

  # Three-valued fold.  `kind` is :any, :all or :none.  The available-case
  # reduction answers wherever an unmasked cell settles the fold (a true for
  # any, a false for all, a true for none); elsewhere a masked cell leaves the
  # answer undetermined.  Going through that reduction checks the data type,
  # the axes and the keywords exactly as `skip_masked: true` does.
  def kleene_fold (kind, opts)
    r = case kind
        when :any then any_skipping_masked(**opts)
        when :all then all_skipping_masked(**opts)
        else           none_skipping_masked(**opts)
        end
    cm = count_masked(**opts)
    if r.is_a?(CArray)
      settled = ( kind == :any ) ? r : r.not
      out = r.copy
      out[settled.not & (cm > 0)] = UNDEF
      out
    else
      settled = ( kind == :any ) ? r : !r
      return r if settled
      ( cm > 0 ) ? UNDEF : r
    end
  end

end
