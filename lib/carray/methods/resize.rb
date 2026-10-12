class CArray

  # @overload resize(*newdim, fill_value: 0)
  #   Returns `self` resized to `newdim`. The original data is
  #   placed at offset 0 (positive size) or right-aligned (negative
  #   size); the new area outside the original region is filled
  #   with `fill_value`, or left as zero storage when it is not given
  #   (0 for a numeric array). Pass `UNDEF` to mask the new area.
  #
  #   Each entry of `newdim` is: `nil` to keep the current
  #   `shape[i]`, a positive Integer for a new size with the
  #   original left-aligned at offset 0, or a negative Integer
  #   `d` for a new size `|d|` with the original right-aligned.
  #
  #   Works on Face arrays (CARecord / CATime / ...) and
  #   plain fixlen: the result is the same Face, and `fill_value` is a
  #   value of it (a Time for a time array).
  #
  #   @param newdim [Array<Integer, nil>] new shape spec, one entry
  #     per axis.
  #   @param fill_value [Object] value for the extended area (zero
  #     storage when not given).
  #   @return [CArray] resized copy.
  NO_FILL_VALUE = ::Object.new.freeze
  private_constant :NO_FILL_VALUE

  def resize (*newdim, fill_value: NO_FILL_VALUE)
    raise ArgumentError, "ndim mismatch" if newdim.size != ndim
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
        raise ArgumentError, "invalid dimension size"
      end
    end
    # The original cells are copied as storage, so a read-only Face (a
    # const string, a categorical) resizes too.  The new area starts as zero
    # storage; a given fill_value is written as a value of the array, which a
    # read-only Face refuses.
    out = __blank_like__(newdim)
    out_storage = out.__send__(:__face_storage__)
    out[] = fill_value unless fill_value.equal?(NO_FILL_VALUE)
    out_storage.mask.paste(offset, self.false) if out_storage.has_mask?
    out_storage.paste(offset, __face_storage__)
    out
  end

end
