class CArray

  # @overload resize(*newdim, fill_value: 0)
  #   Returns `self` resized to `newdim`. The original data is
  #   placed at offset 0 (positive size) or right-aligned (negative
  #   size); the new area outside the original region is filled
  #   with `fill_value`, or -- for fixlen storage -- left as zero
  #   bytes. Pass `UNDEF` to mask the new area.
  #
  #   Each entry of `newdim` is: `nil` to keep the current
  #   `shape[i]`, a positive Integer for a new size with the
  #   original left-aligned at offset 0, or a negative Integer
  #   `d` for a new size `|d|` with the original right-aligned.
  #
  #   Works on Face arrays (CARecord / CATime / ...) and
  #   plain fixlen: the resize is done on the storage layout
  #   (preserving bytes) and re-wrapped as the same Face.
  #
  #   @param newdim [Array<Integer, nil>] new shape spec, one entry
  #     per axis.
  #   @param fill_value [Object] value for the extended area.
  #   @return [CArray] resized copy.
  def resize (*newdim, fill_value: 0)
    raise "ndim mismatch" if newdim.size != ndim
    offset = Array.new(ndim, 0)
    newdim = newdim.each_with_index.map do |d, i|
      case d
      when nil
        shape[i]
      when Integer
        size = d.abs
        offset[i] = size - shape[i] if d < 0
        size
      else
        raise "invalid dimension size"
      end
    end
    face_parent = self.face? ? self : nil
    src = self
    src = src.parent while src.face?
    dt    = src.data_type
    bytes = (dt == :fixlen) ? src.bytes : nil
    out = CArray.new(dt, newdim, bytes: bytes)
    # Fill the new area: numeric storage takes fill_value as-is; fixlen
    # storage cannot hold a numeric 0, so leave zero bytes and honor only
    # UNDEF (mask) or an explicit String fill.
    if dt != :fixlen || fill_value.equal?(UNDEF) || fill_value.is_a?(String)
      out[] = fill_value
    end
    out.mask.paste(offset, src.false) if out.has_mask?
    out.paste(offset, src)
    out = out.face_lift(face_parent) if face_parent
    out
  end

end
