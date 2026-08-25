# Block insert / delete pair (insert_block / delete_block): grow or shrink
# an array by inserting or removing a block region along each axis.

class CArray

  # @overload insert_block(offset, bsize, &block)
  #   Returns a new CArray obtained by inserting a block of size
  #   `bsize` (per axis) at `offset`, growing the array.
  #
  #   Per axis, `offset` accepts `0..shape[i]` (equal to `shape[i]`
  #   appends at the end) and a negative value counts from the end;
  #   `bsize[i]` must be non-negative. Inserted cells are filled by
  #   the block's return value, or left at the type's default when
  #   no block is given. Preserves fixlen bytes and Face identity
  #   (built on the storage layout, re-wrapped via `face_lift`).
  #   The `offset` array is not mutated.
  #
  #   @param offset [Array<Integer>] insertion offset per axis.
  #   @param bsize [Array<Integer>] block size per axis.
  #   @yieldreturn [Object] fill value for the inserted cells.
  #   @return [CArray] grown copy.
  #   @raise [ArgumentError] on `ndim` mismatch or out-of-range
  #     offset / size.
  def insert_block (offset, bsize, &block)
    if offset.size != ndim or bsize.size != ndim
      raise ArgumentError, "ndim mismatch"
    end
    offset = offset.dup           # normalize without mutating the caller's array
    newdim = shape
    grids = shape.map{|d| CArray.int32(d) }
    ndim.times do |i|
      offset[i] += shape[i] if offset[i] < 0
      if offset[i] < 0 or offset[i] > shape[i] or bsize[i] < 0
        raise ArgumentError, "invalid offset or size at axis #{i}"
      end
      if bsize[i] > 0
        newdim[i] += bsize[i]
      end
      grids[i][0...offset[i]].seq! if offset[i] > 0
      # offset == dim (append) leaves nothing on the upper side to shift.
      grids[i][offset[i]..-1].seq!(offset[i]+bsize[i]) if offset[i] < shape[i]
    end
    # Build at the storage layout (preserving bytes for fixlen / Face),
    # then re-wrap as the same Face.
    face_parent = self.face? ? self : nil
    src = self
    src = src.parent while src.face?
    dt    = src.data_type
    bytes = (dt == :fixlen) ? src.bytes : nil
    out = CArray.new(dt, newdim, bytes: bytes)
    if block_given?
      sel = out.true
      sel[*grids] = 0
      out[sel] = block.call
    end
    out[*grids] = src
    out = out.face_lift(face_parent) if face_parent
    return out
  end

  # @overload delete_block(offset, bsize)
  #   Returns a new CArray obtained by deleting a block of `bsize`
  #   cells (per axis) starting at `offset`, shrinking the array.
  #
  #   Per axis, `offset` accepts `0..shape[i]-1` (negative counts
  #   from the end) and `bsize[i]` must be non-negative with
  #   `offset[i] + bsize[i] <= shape[i]`. Bytes and Face identity
  #   are preserved naturally because the result is built by
  #   fancy-index copy of `self`. The `offset` array is not mutated.
  #
  #   @param offset [Array<Integer>] start of the block per axis.
  #   @param bsize [Array<Integer>] block size per axis.
  #   @return [CArray] shrunk copy.
  #   @raise [ArgumentError] on `ndim` mismatch or out-of-range
  #     offset / size.
  def delete_block (offset, bsize)
    if offset.size != ndim or bsize.size != ndim
      raise ArgumentError, "ndim mismatch"
    end
    offset = offset.dup           # normalize without mutating the caller's array
    newdim = shape
    grids  = []
    ndim.times do |i|
      offset[i] += shape[i] if offset[i] < 0
      if bsize[i] < 0 or offset[i] < 0 or offset[i] >= shape[i] or
          offset[i] + bsize[i] > shape[i]
        raise ArgumentError, "invalid offset or size at axis #{i}"
      end
      newdim[i] -= bsize[i]
      grids[i] = CArray.int32(newdim[i])
      grids[i][0...offset[i]].seq! if offset[i] > 0
      if offset[i] + bsize[i] < shape[i]
        grids[i][offset[i]..-1].seq!(offset[i]+bsize[i])
      end
    end
    return self[*grids].copy
  end

end
