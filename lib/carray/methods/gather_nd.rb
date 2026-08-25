#  N-D arbitrary-position gather / scatter (CArray implementation of
#  TensorFlow `gather_nd` / `scatter_nd_update`).
#
#  Natural N-D extension of `take_along_axis` (= fiber-aligned gather along axis).
#  Treats the trailing K axes of `indices.shape = (..., K)` as coordinate tuples
#  and consumes the first K axes of params while carrying the remaining axes (= rest).
#
#  Implementation goes through a CAMapping view of the flattened array:
#  `params.flatten[flat_addr]`.  Pure Ruby, no additional framework, composed
#  entirely from existing indexers as in `take_along_axis`.  Since CAMapping is
#  writable, write-through via `put_nd` uses last-write-wins semantics (= last
#  value wins on duplicate indices, same contract as `put_along_axis`).  For
#  accumulate semantics, route to the `scatter_*!` family instead.

class CArray

  # @overload gather_nd(indices)
  #   Returns elements (or sub-arrays) gathered from `self` at the
  #   N-D coordinates given by `indices`.
  #
  #   `indices` accepts two equivalent forms:
  #
  #   * **stacked** — a single CArray whose last axis enumerates a
  #     K-dimensional coordinate tuple into the first K axes of `self`.
  #   * **per-axis** — an `Array` of K coordinate CArrays (one per
  #     consumed axis).  The per-axis arrays are broadcast together
  #     (via {CArray.broadcast}) and stacked along a new trailing axis,
  #     so `gather_nd([i, j])` == `gather_nd(CArray.stack([i, j], axis: -1))`.
  #     An Integer scalar is accepted for a constant axis and broadcast
  #     to the common shape.  Entries must be CArray or Integer: Ruby
  #     Array literals are rejected (wrap them with `CA_INT64(...)`
  #     yourself), keeping this a copy-free gather path.
  #
  #   The remaining `self.shape[K..-1]` axes (called `rest`) are carried
  #   through:
  #
  #       self.shape    = (D0, ..., D_{K-1}, *rest)
  #       indices.shape = (*outer, K)          # stacked form
  #       result.shape  = (*outer, *rest)
  #
  #   In the fully-degenerate case where both `outer` and `rest` are
  #   empty (a single full coordinate via 1-D `indices` of shape `(K,)`
  #   with `K == ndim`), the result is a 1-element `(1,)` CArray,
  #   following CArray's scalar model (CScalar carries shape `[1]`),
  #   not a 0-dim array.
  #
  #   The result is a fresh materialised CArray. Negative indices on
  #   each coordinate axis follow CArray's standard wrap rule
  #   (`-1` == last); out-of-range indices raise. Duplicate
  #   coordinates in `indices` are fine on gather: the same value is
  #   picked multiple times. See {#put_nd} for the duplicate-write
  #   story.
  #
  #   @param indices [CArray, Array<CArray, Integer>] stacked integer
  #     CArray with `ndim >= 1` and last axis size `K` in `[1, ndim]`,
  #     or an Array of K per-axis coordinate CArrays (Integer scalars
  #     allowed per axis).
  #   @return [CArray] materialised result with shape `outer + rest`.
  #   @raise [ArgumentError] when `indices` is neither a CArray nor an
  #     Array, is 0-dim, is non-integer, or has a last-axis size
  #     outside `[1, ndim]`.
  #   @raise [IndexError] when a coordinate is out of range on any axis.
  def gather_nd (indices)
    flat_addr, outer, rest = gather_nd_flat_addr(indices, "gather_nd")
    out_shape = outer + rest
    # flatten + 1-D fancy indexing -> CAMapping view -> materialise via .copy.
    result = self.flatten[flat_addr].copy
    out_shape.empty? ? result : result.reshape(*out_shape)
  end

  # @overload put_nd(indices, values)
  #   Sets `self` at the N-D coordinates given by `indices` to
  #   `values`. Inverse of {#gather_nd}.
  #
  #       self.shape    = (D0, ..., D_{K-1}, *rest)
  #       indices.shape = (*outer, K)
  #       values          broadcast to (*outer, *rest)
  #
  #   Duplicate coordinates in `indices` use **last-write-wins**
  #   semantics, matching `put_along_axis`. Accumulate semantics
  #   (`+=`) are not provided here; route to the `scatter_*!`
  #   family instead (e.g. `self.flatten.scatter_add!(flat_addr, vals)`).
  #
  #   @param indices [CArray, Array<CArray, Integer>] stacked integer
  #     CArray shaped `(*outer, K)`, or an Array of K per-axis
  #     coordinate arrays (same forms as {#gather_nd}).
  #   @param values [CArray, Numeric] values broadcastable to
  #     `(*outer, *rest)`.
  #   @return [self]
  #   @raise [ArgumentError] on the same conditions as {#gather_nd}.
  #   @raise [IndexError] when a coordinate is out of range on any axis.
  def put_nd (indices, values)
    flat_addr, _outer, _rest = gather_nd_flat_addr(indices, "put_nd")
    self.flatten[flat_addr] = values
    self
  end

  private

  # Shared helper: compute the flat-address CArray (shape = outer + rest)
  # for both `gather_nd` and `put_nd`.  Returns `[flat_addr, outer, rest]`.
  def gather_nd_flat_addr (indices, name)
    # Per-axis form: an Array of K coordinate arrays.  Broadcast them to a
    # common outer shape and stack along a new trailing axis, yielding the
    # (*outer, K) stacked form the rest of this helper already handles.
    indices = gather_nd_stack_axes(indices, name) if indices.is_a?(Array)

    unless indices.is_a?(CArray)
      raise ArgumentError, "#{name}: indices must be a CArray or an Array of per-axis CArrays"
    end
    if indices.ndim == 0
      raise ArgumentError, "#{name}: indices must have at least 1 dimension"
    end
    unless indices.integer?
      raise ArgumentError,
            "#{name}: indices must be an integer CArray (got #{indices.data_type})"
    end

    k = indices.shape[-1]
    unless k.is_a?(Integer) && k >= 1 && k <= ndim
      raise ArgumentError,
            "#{name}: indices last-axis size #{k} out of [1, #{ndim}]"
    end

    outer = indices.shape[0..-2]            # may be []
    rest  = (k < ndim) ? shape[k..-1] : []  # may be []
    m     = outer.empty? ? 1 : outer.inject(:*)
    rest_size = rest.empty? ? 1 : rest.inject(:*)

    # Stride per consumed axis i = product of params.shape[(i+1)..-1]
    # (covers remaining consumed axes + all rest axes).
    strides_a = (0...k).map { |i| shape[(i+1)..-1].inject(1, :*) }
    strides   = CA_INT64(strides_a).reshape(1, k)

    # Per-axis dimension for negative-index normalize + OOB check.
    dims = CA_INT64(shape[0...k]).reshape(1, k)

    flat_idx_raw = indices.reshape(m, k)

    # OOB check (per-axis): require -dim <= idx < dim on every coordinate.
    if (flat_idx_raw >= dims).any
      raise IndexError, "#{name}: coordinate >= dim on some axis"
    end
    if (flat_idx_raw < -dims).any
      raise IndexError, "#{name}: coordinate < -dim on some axis"
    end

    # Wrap negatives: (-dim..-1) -> (0..dim-1) via (idx + dim) % dim.
    # Safe under -dim <= idx < dim (just checked).
    flat_idx = (flat_idx_raw + dims) % dims

    base     = (flat_idx * strides).sum(axis: 1).int64.reshape(m)  # (M,)

    flat_addr =
      if rest.empty?
        base                                # (M,)
      else
        offsets = CArray.int64(rest_size).seq
        base.reshape(m, 1) + offsets.reshape(1, rest_size)  # (M, rest_size)
      end

    [flat_addr, outer, rest]
  end

  # Convert the per-axis form (an Array of K coordinate arrays) into the
  # stacked `(*outer, K)` CArray.  Coordinate arrays are broadcast to a
  # common `outer` shape (via CArray.broadcast, which rejects cross-ndim
  # implicit align) and stacked along a new trailing axis.  Integer
  # scalars are accepted per axis and expand to the common shape; an
  # all-scalar list yields the 1-D `(K,)` single-coordinate form.
  def gather_nd_stack_axes (list, name)
    if list.empty?
      raise ArgumentError, "#{name}: coordinate list must not be empty"
    end

    # This is a high-performance gather path: per-axis entries must be
    # CArray coordinate arrays (or a bare Integer scalar for a constant
    # axis).  Ruby Arrays are rejected on purpose -- coercing them via
    # CA_INT64 on every call would defeat the point of the API; wrap them
    # yourself once (CA_INT64(...)) if you have array literals.
    list.each do |c|
      unless c.is_a?(CArray) || c.is_a?(Integer)
        raise ArgumentError,
              "#{name}: per-axis coordinate must be a CArray or Integer (got #{c.class})"
      end
    end

    # All scalars -> a single K-coordinate tuple (degenerate stacked form).
    if list.none? { |c| c.is_a?(CArray) }
      return CA_INT64(list)
    end

    coords = CArray.broadcast(*list, expand_scalar: true)
    ref    = coords.find { |c| c.is_a?(CArray) && !c.is_a?(CScalar) }
    coords = coords.map do |c|
      case c
      when CArray
        c
      else                       # Integer scalar on this axis
        CArray.int64(*ref.shape) { c }
      end
    end
    CArray.stack(coords, axis: -1)
  end

end
