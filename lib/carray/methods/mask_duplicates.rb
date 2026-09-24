require "carray/methods/discovery_along"

class CArray

  # @overload mask_duplicates(axis: nil)
  #   Returns a shape-preserving copy of `self` with the mask set at
  #   every cell whose value duplicates an earlier-seen one; the
  #   first occurrence is kept.
  #
  #   With `axis: nil` duplicates are detected in flatten (row-major)
  #   order across the whole array. With `axis: k` duplicates are
  #   detected per-fiber along axis `k`, independently for each
  #   fiber. Marking duplicates (not compressing) is what makes the
  #   per-axis form expressible: fibers may hold different numbers of
  #   distinct values, so a compressed result would be ragged.
  #
  #   Distinctness matches the value-hash discovery family. Numeric:
  #   `==` with all NaN collapsed to one value (so the second and
  #   later NaN are duplicates) and -0.0 == +0.0. `CA_OBJECT` /
  #   `CA_FIXLEN`: Ruby `eql?` / `hash` (distinct NaN objects stay
  #   distinct). Masked input cells stay masked and do not participate
  #   in duplicate judging. Both `axis: nil` and `axis: k` work.
  #
  #   @param axis [Integer, nil] axis to detect duplicates along;
  #     `nil` uses flatten order.
  #   @return [CArray] shape-preserving copy of `self` with
  #     duplicates masked.
  # @overload mask_duplicates(along: k)
  #   Returns a shape-preserving copy of `self` with every cell of a
  #   duplicated **sub-array** masked, comparing whole sub-arrays rather
  #   than cells: `along: k` names the axis whose index enumerates them,
  #   so `z.mask_duplicates(along: 0)` masks each repeated row of a 2-D
  #   array and keeps the first occurrence.
  #
  #   Note the contrast with `axis:`, which names the axis a *fiber runs
  #   along* and marks repeated values inside each fiber. The two cannot
  #   be given together.
  #
  #   A sub-array holding a masked cell does not participate: it is
  #   neither judged a duplicate nor able to make a later one, and its
  #   cells keep the mask they came with. `object` arrays are refused,
  #   because their cells hold Ruby references.
  #
  #   @param along [Integer] axis whose index enumerates the sub-arrays.
  #   @return [CArray] shape-preserving copy of `self` with duplicated
  #     sub-arrays masked.
  def mask_duplicates (axis: nil, along: nil)
    reject_axis_with_along(axis, along, "mask_duplicates")
    if along
      keys = fibers_as_cells(along, "mask_duplicates")
      #  A sub-array that did not participate (it held a masked cell) is
      #  masked in `keys` already; only the ones that did and repeated
      #  are duplicates here.
      repeated = keys.mask_duplicates.is_masked & keys.is_not_masked
      args = [:_] * ndim
      args[normalize_axis(along, "mask_duplicates")] = nil
      spread = CArray.boolean(*shape)
      spread[] = repeated[*args]
      return mask_where(spread)
    end
    dup =
      if axis.nil?
        # One seen-set over the flattened array, then restore shape.
        flatten.send(:__mask_duplicates__, 0).reshape(*shape)
      else
        # Per-fiber single-pass seen-set hash (C __mask_duplicates__): one lane
        # per data type family (integer widen, float bitwise key with NaN collapse,
        # object rb_hash + rb_eql, fixlen byte-hash + memcmp, boolean via the
        # uint8 lane). O(distinct) memory, no sort/gather/scatter buffers.
        __mask_duplicates__(normalize_axis(axis, "mask_duplicates"))
      end
    mask_where(dup)
  end

end
