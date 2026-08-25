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
  def mask_duplicates (axis: nil)
    dup =
      if axis.nil?
        # One seen-set over the flattened array, then restore shape.
        flatten.send(:__mask_duplicates__, 0).reshape(*shape)
      else
        # Per-fiber single-pass seen-set hash (C __mask_duplicates__): one lane
        # per dtype family (integer widen, float bitwise key with NaN collapse,
        # object rb_hash + rb_eql, fixlen byte-hash + memcmp, boolean via the
        # uint8 lane). O(distinct) memory, no sort/gather/scatter buffers.
        __mask_duplicates__(normalize_axis(axis, "mask_duplicates"))
      end
    mask_where(dup)
  end

end
