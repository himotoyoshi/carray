class CArray

  # User-facing YARD docs for #locate_addr and #locate_nearest_addr live
  # in yard-stubs/carray_order.rb (grouped with the search family).

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

end
