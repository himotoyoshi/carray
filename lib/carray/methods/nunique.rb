class CArray

  # @overload nunique(axis: nil, keep_axis: false)
  #   Counts the distinct values of `self`. This is the scalar-reduction
  #   member of the value-hash discovery family ({#unique},
  #   {#mask_duplicates}, {#value_counts}): where {#unique} compresses
  #   and {#value_counts} tabulates, `nunique` just counts.
  #
  #   With `axis: nil` (default) it counts distinct values across the
  #   whole array and returns an Integer. With `axis: k` it counts per
  #   fiber along axis `k`, returning a reduced `CA_INT64` CArray
  #   (shape = self.shape with axis `k` removed; `keep_axis: true` keeps
  #   it as a length-1 axis). The shape rule matches other per-axis
  #   reductions such as `sum(axis:)`.
  #
  #   The distinct count has identity 0: an empty array, an all-masked
  #   fiber, or a zero-length axis counts 0 (not UNDEF) — an empty set
  #   has zero distinct values. Masked cells do not participate.
  #
  #   Numeric distinctness follows `==` with the family's two float
  #   special cases: all NaN collapse to a single value and
  #   -0.0 / +0.0 are the same value. For `CA_OBJECT` / `CA_FIXLEN`
  #   distinctness follows Ruby `eql?` / `hash` (which, unlike numeric,
  #   does not collapse distinct NaN objects).
  #
  #   @param axis [Integer, nil] axis to count along; `nil` counts over
  #     the whole array.
  #   @param keep_axis [Boolean] when `axis` is given, keep the reduced
  #     axis as a length-1 axis instead of dropping it.
  #   @return [Integer, CArray] Integer for `axis: nil`, otherwise a
  #     reduced `CA_INT64` CArray.
  def nunique (axis: nil, keep_axis: false)
    # Per-fiber single-pass seen-set hash (C __nunique__), one lane per dtype
    # family (numeric widen / NaN collapse, object rb_hash + rb_eql, fixlen
    # byte-hash + memcmp). Masked cells are skipped; the accumulator is a no-op
    # (the distinct count is the interned-key count).
    if axis.nil?
      # Whole-array distinct count: flatten to 1-D and reduce its only axis,
      # then read the single reduced cell as an Integer.
      flatten.send(:__nunique__, 0, false)[0]
    else
      __nunique__(normalize_axis(axis, "nunique"), keep_axis)
    end
  end

end
