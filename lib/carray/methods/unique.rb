require "carray/methods/discovery_along"

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
  #   Distinctness follows `==` for numeric data types, with two float
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
  #   @return [CArray] 1-D CArray of the distinct values, same data type
  #     as `self`.
  #
  # @overload unique(along: k)
  #   Returns the distinct **sub-arrays** of `self`, comparing whole
  #   sub-arrays rather than cells: `along: k` names the axis whose
  #   index enumerates them, so `z.unique(along: 0)` gives the distinct
  #   rows of a 2-D array, in first-appearance order. This is
  #   `np.unique(z, axis=k)`.
  #
  #   Note the contrast with `axis:` on {#nunique} and
  #   {#mask_duplicates}, which names the axis a *fiber runs along* and
  #   asks about the values inside each fiber. The two cannot be given
  #   together.
  #
  #   Distinctness is the family's, widened from a cell to a sub-array:
  #   two sub-arrays are the same when every cell is, with all NaN one
  #   value and -0.0 == +0.0. A sub-array holding a masked cell does not
  #   participate and never appears in the result.
  #
  #   The result is a **view** of `self` -- the surviving sub-arrays,
  #   not copies of them -- so writing through it reaches `self`. Take a
  #   `copy` when that is not wanted. `sort:` is not available here:
  #   sub-arrays have no order to sort by. `object` arrays are refused,
  #   because their cells hold Ruby references.
  #
  #   @param along [Integer] axis whose index enumerates the sub-arrays.
  #   @return [CArray] the distinct sub-arrays, same shape as `self`
  #     except along `along`.
  def unique (sort: false, along: nil)
    if along
      if sort
        raise ArgumentError,
              "unique: sort: is not available with along: -- sub-arrays have " \
              "no order to sort by; the result is in first-appearance order"
      end
      keys = fibers_as_cells(along, "unique")
      args = [nil] * ndim
      args[normalize_axis(along, "unique")] = keys.mask_duplicates.is_not_masked
      return self[*args]
    end
    # Single-pass seen-set hash (C __unique_flat__), one lane per data type family:
    # integer widens to a 64-bit key; float uses the bitwise key with all-NaN
    # collapsed and -0.0 / +0.0 normalized; object keys on rb_hash + rb_eql and
    # fixlen on a byte-hash + memcmp, both reproducing Ruby Hash distinctness.
    # Masked cells are skipped in the kernel.
    levels = __unique_flat__
    sort ? levels.sort : levels
  end

end
