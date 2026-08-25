class CArray

  # @overload unique(sort: false)
  #   Returns a 1-D CArray of the distinct values of `self`, in
  #   first-appearance (row-major flatten) order. This is the
  #   compressing counterpart of {#mask_duplicates} (which marks
  #   without compressing): because different fibers may hold
  #   different numbers of distinct values, compression is only
  #   well-defined over the whole array, so `unique` is always flat.
  #
  #   Named `unique` (not `uniq`) because distinctness is value-based
  #   like NumPy / pandas `unique`: unlike Ruby `Array#uniq` it
  #   collapses all NaN to a single value (see below), so the name
  #   avoids promising `Array#uniq` semantics.
  #
  #   Masked cells do not participate and never appear in the result;
  #   an all-masked array yields an empty CArray.
  #
  #   Distinctness follows `==` for numeric dtypes, with two float
  #   special cases so the result matches value-based expectations:
  #   all NaN collapse to a single distinct value (rather than one per
  #   cell) and -0.0 / +0.0 are the same value. The value kept for
  #   each key is the first one seen, so a leading -0.0 keeps its sign.
  #   For `CA_OBJECT` / `CA_FIXLEN` distinctness follows Ruby
  #   `eql?` / `hash`; note that Ruby does not collapse distinct NaN
  #   objects, so a `CA_OBJECT` array of Float NaN is not collapsed
  #   (unlike the numeric path).
  #
  #   @param sort [Boolean] when true, return the distinct values
  #     sorted ascending instead of in first-appearance order.
  #   A time array (`CATime` / `CATimedelta`) answers with its own type on
  #   its own unit: the distinct values are values, so the array comes back
  #   as itself rather than as raw storage ticks.
  #
  #   @return [CArray] 1-D CArray of the distinct values, same dtype
  #     as `self`.
  def unique (sort: false)
    # Single-pass seen-set hash (C __unique_flat__), one lane per dtype family:
    # integer widens to a 64-bit key; float uses the bitwise key with all-NaN
    # collapsed and -0.0 / +0.0 normalized; object keys on rb_hash + rb_eql and
    # fixlen on a byte-hash + memcmp, both reproducing Ruby Hash distinctness.
    # Masked cells are skipped in the kernel.
    levels = __unique_flat__
    sort ? levels.sort : levels
  end

end
