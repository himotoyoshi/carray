class CArray

  # @overload value_counts(sort: false)
  #   Returns `[values, counts]`, the distinct values of `self` paired
  #   with the number of times each occurs. `values` is a 1-D CArray of
  #   `self`'s dtype; `counts` is a 1-D `CA_INT64` where `counts[i]` is
  #   the number of occurrences of `values[i]`. This is the frequency-
  #   table member of the value-hash discovery family ({#unique},
  #   {#mask_duplicates}, {#nunique}); like {#unique} it always
  #   flattens, because per-fiber distinct counts would be ragged.
  #
  #   By default the pairs are in first-appearance (row-major flatten)
  #   order, matching {#unique}. `sort:` reorders both arrays together:
  #
  #   - `false` (default) — first-appearance order.
  #   - `:count` — descending frequency; ties keep first-appearance
  #     order (deterministic).
  #   - `:value` — ascending value (float NaN sorts last, as in
  #     `unique(sort: true)`).
  #
  #   Masked cells do not participate and never appear; an all-masked
  #   array yields two empty CArrays.
  #
  #   Numeric distinctness follows `==` with two float special cases so
  #   the result matches value-based expectations: all NaN collapse to a
  #   single value (their counts add up) and -0.0 / +0.0 are the same
  #   value (the first-seen value is kept, so a leading -0.0 keeps its
  #   sign). For `CA_OBJECT` / `CA_FIXLEN` distinctness follows Ruby
  #   `eql?` / `hash`; Ruby does not collapse distinct NaN objects, so a
  #   `CA_OBJECT` array of Float NaN is not collapsed (unlike numeric).
  #
  #   @param sort [false, :count, :value] pair ordering.
  #   The values keep `self`'s type (a `CATime` comes back as a `CATime` on
  #   its own unit); the counts are always a plain `:int64` CArray.
  #
  #   @return [Array(CArray, CArray)] `[values, counts]`.
  def value_counts (sort: false)
    unless [false, :count, :value].include?(sort)
      raise ArgumentError, "value_counts: sort must be false, :count, or :value"
    end
    # Single-pass frequency-table hash (C __value_counts_flat__), one lane per
    # dtype family: integer widens to a 64-bit key; float uses the bitwise key
    # with all NaN collapsed and -0.0 / +0.0 normalized; object keys on rb_hash +
    # rb_eql and fixlen on a byte-hash + memcmp, both reproducing Ruby Hash
    # distinctness. Masked cells are skipped in the kernel.
    values, counts = __value_counts_flat__
    case sort
    when :count
      # Descending count, ties broken by first-appearance index (stable).
      c = counts.to_a
      order = (0...c.size).sort_by { |i| [-c[i], i] }
      [ values[CArray.int64(order.size) { |i| order[i] }],
        counts[CArray.int64(order.size) { |i| order[i] }] ]
    when :value
      # Ascending value; NaN (numeric) or non-comparable last. Build the
      # permutation with an explicit NaN-last key so float NaN doesn't blow up
      # the Ruby sort, then gather both arrays through it.
      v = values.to_a
      order = (0...v.size).sort_by do |i|
        x = v[i]
        nan = x.is_a?(Float) && x.nan?
        [nan ? 1 : 0, nan ? 0 : x, i]
      end
      [ values[CArray.int64(order.size) { |i| order[i] }],
        counts[CArray.int64(order.size) { |i| order[i] }] ]
    else
      [values, counts]
    end
  end

end
