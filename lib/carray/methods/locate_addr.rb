class CArray

  # @!group Sorting and searching

  # @overload locate_addr(ref)
  #   Returns, for each element of `self`, the flat address into `ref`
  #   where the value first occurs, or `UNDEF` where it is not present.
  #   Builds a value-to-first-address map from `ref` in one pass (an
  #   open-addressing hash, the same substrate as {#unique} /
  #   {#value_counts}), then probes each element of `self`; no sort,
  #   peak memory `O(distinct ref values)`.
  #
  #   The return is `ref`'s flat address (0 to `ref.elements - 1`), so a
  #   multi-dimensional `ref` still yields a `self`-shaped result of flat
  #   addresses; downstream reads (`ref[addr]`, `model_var[addr]`, ...)
  #   apply it as a flat gather.
  #
  #   Works on numeric, `CA_OBJECT`, and `CA_FIXLEN` values, matching the
  #   value-hash discovery family: numeric follows `==` with all NaN
  #   collapsed to one value and `-0.0 == +0.0`; object follows Ruby
  #   `hash` / `eql?` with Float NaN collapsed; fixlen follows byte
  #   equality. When `ref` holds duplicate values the returned address is
  #   the earliest (appearance-order) occurrence. Masked cells of `ref` do
  #   not enter the map but still occupy their flat address; masked cells
  #   of `self` are `UNDEF` in the result.
  #
  #   `self` and `ref` are compared at their common type, negotiated by
  #   `CArray.result_type` — a fractional query against an integer `ref`
  #   is compared at the promoted type rather than truncated, so `1.5` no
  #   longer matches `1`. Cross-family input (numeric against fixlen)
  #   raises.
  #
  #   Typical use is time-axis lookup: compute the address once against a
  #   reference axis, then reuse it to gather from many `ref`-shaped
  #   variables without repeating the lookup.
  #
  #   @param ref [CArray, Array, Range] reference values to match against;
  #     any shape (used as flat). An Array or Range is coerced with `to_ca`
  #     and so lands in `:object`, where numeric matching follows Ruby
  #     `eql?` (`2.0` does not match `2`); pass a CArray to match in a
  #     numeric lane.
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape as
  #     `self`; unmatched cells are masked.
  #   @raise [RuntimeError] when `self` and `ref` have no common data type.
  def locate_addr (ref)
    ref = ref.to_ca unless ref.is_a?(CArray)
    # Put self and ref in a common lane via the single-source promotion rule
    # (CArray.result_type), so a fractional query against an int ref is compared
    # at the promoted type instead of truncating (1.5 no longer matches 1).
    # to_type is elementwise and order-preserving, so the addresses stay valid
    # indices into ref. result_type raises for cross-family input.
    t = CArray.result_type(self, ref)
    q = (data_type     == t) ? self : to_type(t)
    r = (ref.data_type == t) ? ref  : ref.to_type(t)
    q.send(:__locate_addr__, r)
  end

  # @overload locate_nearest_addr(ref, direction: :round, tolerance: nil)
  #   Returns, for each element of `self`, the flat address into `ref` of
  #   the nearest reference value. Continuous sibling of {#locate_addr};
  #   uses `linear_section` + rounding for non-exact matching against a
  #   sorted `ref`.
  #
  #   Out-of-range cells of `self` (outside `ref`'s span) mask through the
  #   pipeline: `linear_section` returns NaN, `mask_invalid` propagates
  #   that as `UNDEF`, rounding and the int64 cast carry the mask, and
  #   `project` scatters it into the final positions. `mask_invalid` runs
  #   before rounding because `CArray#round` maps NaN to 0 and would
  #   otherwise silently match `ref[0]`.
  #
  #   `tolerance:` (default `nil`) sets a maximum accepted absolute
  #   distance between `self[i]` and its matched `ref` value. When
  #   `|ref[addr] - self[i]| > tolerance`, the result cell is masked. Use
  #   for accuracy-controlled matching (e.g. "an observation snaps to a
  #   time step only if within N seconds").
  #
  #   `ref` need not be given in ascending order: it is sorted internally
  #   and the returned addresses are mapped back to positions in `ref` as
  #   passed.
  #
  #   @param ref [CArray] 1-D reference grid to match against.
  #   @param direction [Symbol] `:round`, `:floor`, or `:ceil` — rounding
  #     applied to the fractional position.
  #   @param tolerance [Numeric, nil] maximum accepted `|self - ref|`
  #     distance; cells beyond this are masked. `nil` disables the check.
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape as
  #     `self`; out-of-range and beyond-tolerance cells are masked.
  #   @raise [ArgumentError] when `direction` is not one of the accepted
  #     symbols.
  def locate_nearest_addr (ref, direction: :round, tolerance: nil)
    unless [:round, :floor, :ceil].include?(direction)
      raise ArgumentError,
            "locate_nearest_addr: direction must be :round / :floor / " \
            ":ceil (got #{direction.inspect})"
    end
    ri = ref.sort_addr
    rs = ref[ri]
    sec = rs.linear_section(self)
    unless sec.is_a?(CArray)
      # A single-element (scalar-like) self makes linear_section collapse to
      # its scalar-query path, which returns a bare Float (or nil when out of
      # range) instead of a CArray.  Rebuild a self-shaped float64 CArray so
      # the mask_invalid -> direction -> project pipeline stays array-valued
      # and the returned addr array matches self's shape.
      fill = CArray.float64(*shape)
      fill[] = sec.nil? ? UNDEF : sec
      sec = fill
    end
    masked = sec.mask_invalid
    si = case direction
         when :round then masked.round
         when :floor then masked.floor
         when :ceil  then masked.ceil
         end.int64
    idx = ri.project(si)
    if tolerance
      dist = (ref.project(idx) - self).abs
      idx[dist > tolerance] = UNDEF
    end
    idx
  end

  # @!endgroup

end
