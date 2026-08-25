# CAStack view-default composition surface
#
# This file holds the composition methods that build (directly or via
# reshape/transpose) a CAStack view from storage-uniform pieces:
#
#   stack   = K parents pushed onto a new K axis
#   meld    = melt + weld; pieces dissolve their boundaries along the
#             named axis and are regarded as one (uniform)
#   montage = uniform tiles arranged in a regular grid (ImageMagick)
#
# Their ragged eager counterparts (concatenate / mosaic / tabulate) live in
# carray/methods/composition.rb.  See that file's header for the full
# composition cheat sheet.
#
# Examples (a, b, c are each shape [3, 4]):
#
#   CArray.stack([a, b, c])                       #=> view, shape (3, 3, 4)   (K outermost)
#   CArray.stack([a, b, c], axis: -1)             #=> view, shape (3, 4, 3)   (RGB pattern)
#   CArray.meld([a, b, c])                        #=> view, shape (9, 4)
#   CArray.meld([a, b, c], axis: 1)               #=> view, shape (3, 12)
#   CArray.montage([a, b, c, d], [2, 2], axis: 0) #=> view, shape (6, 8) (2x2 image tile)
#
# Known limitation: scalar indexing on a CAStack-rooted view drops ndim
# and triggers a full
# materialise fallback.  Use range indexing (e.g. `meld(...)[k..k, nil]`
# instead of `meld(...)[k, nil]`) for partial-use perf, or `.to_ca` upfront
# to materialise eagerly.

class CArray

  # ---------------------------------------------------------------- view-default

  # Stack `list` of CArrays along a new axis inserted at position
  # `axis:` (default 0 = outermost).  Returns a view
  # (CAStack with k_axis = axis) when inputs are storage-uniform, or a
  # Face-lifted view (= CATime, CATimedelta, ...) when inputs are
  # homogeneous Face instances.  Call `.to_ca` to materialise eagerly.
  #
  # `data_type:` kwarg (optional, primitive Symbol only) forces primitive
  # promotion; cannot be used when the list contains Face elements.  Class
  # / Module targets are rejected (= `data_type: CATime` is invalid;
  # use auto-detect for Face round-trip).
  #
  # 3.0 (post-K_AXIS, F.S1-stack landed): replaces `CArray.merge`.  The
  # low-level raw constructor is `CAStack.new(list, axis:)`; this method
  # is the high-level surface that performs promote_list + CAStack.new +
  # (face_lift when homogeneous Face).
  # @overload stack(list, axis: 0, data_type: nil)
  #   Returns a view stacking uniform-shape arrays along a new K
  #   axis at position `axis`. Runs `promote_list` for a common
  #   `data_type` and re-wraps homogeneous Face inputs via
  #   `face_lift`. Output `ndim` is one greater than each piece.
  #   @param list [Array<CArray>] pieces to stack; must not be empty.
  #   @param axis [Integer] position of the new K axis.
  #   @param data_type [Symbol, Integer, nil] result `data_type`;
  #     inferred when `nil`.
  #   @return [CArray] CAStack view.
  #   @raise [ArgumentError] when `list` is empty.
  def self.stack (list, axis: 0, data_type: nil)
    raise ArgumentError, "stack: list must not be empty" if list.empty?
    list = CArray.promote_list(list, data_type: data_type)
    axis = CArray.normalize_axis(axis, list[0].ndim + 1, "stack")
    CAStack.new(list, axis: axis)                # CAStack.new does Face lift internally
  end

  # Returns a {CAMeld} view of the arrays welded along an existing axis.
  # No data is copied; reads gather from parents on demand and writes flow
  # back to them (chain composability preserved).
  #
  # Pieces must agree on `ndim`, `data_type`, byte width, and every axis
  # length except `axis` (the "meld axis").  Mismatched `data_type` raises:
  # cast the pieces yourself (`.to_type(:float64)`) or use
  # {CArray.concatenate} (eager, auto-casts).
  #
  # "meld" = melt + weld — pieces dissolve their boundaries along the named
  # axis and are regarded as one.
  #
  # @overload meld(*arrays, axis: 0)
  # @overload meld(list, axis: 0)
  #   Convenience form: a single Array argument is treated as the list.
  #   @param arrays [Array<CArray>] pieces to weld.  A single Array
  #     argument is accepted for compatibility with older callers.
  #   @param axis [Integer] existing axis to extend (normalises negative
  #     values against the reference ndim).
  #   @return [CAMeld] view over the welded pieces.
  #   @raise [ArgumentError] when the list is empty, ndim mismatch,
  #     data_type mismatch, or non-axis dim mismatch across pieces
  #     (surfaced by CAMeld.new).
  def self.meld (*arrays, axis: 0)
    if arrays.length == 1 && arrays[0].is_a?(Array)
      arrays = arrays[0]
    end
    raise ArgumentError, "meld: list must not be empty" if arrays.empty?
    first = arrays[0]
    unless first.is_a?(CArray)
      raise ArgumentError, "meld: entries must be CArray (got #{first.class})"
    end
    axis_norm = CArray.normalize_axis(axis, first.ndim, "meld")
    # Flatten nested CAMeld inputs that share our meld axis: they already
    # describe a segment sequence, so absorbing their parents keeps chain
    # depth at 1 (avoids 2-level xfer_all / reduce chains through the
    # intermediate CAMeld).  A CAMeld with a different meld_axis is left
    # intact — its segment structure is orthogonal.
    if arrays.any? { |a| a.is_a?(CAMeld) && a.meld_axis == axis_norm }
      arrays = arrays.flat_map { |a|
        a.is_a?(CAMeld) && a.meld_axis == axis_norm ? a.parents : [a]
      }
    end
    CAMeld.new(arrays, axis: axis_norm)
  end
end

class CArray
  # Returns a {CAMeld} view of `[self, *others]` welded along `axis`.
  # Instance form of {CArray.meld}; non-destructive, see the class method
  # for full semantics.
  #
  # @overload meld(*others, axis: 0)
  #   @param others [Array<CArray>] additional pieces.
  #   @param axis [Integer] existing axis to extend.
  #   @return [CAMeld]
  #   @raise [ArgumentError] when no `others` are given.
  def meld (*others, axis: 0)
    raise ArgumentError, "meld: at least one other array required" if others.empty?
    CArray.meld(self, *others, axis: axis)
  end

  # Arrange `list` of uniform-shape pieces in a `tdim`-shape grid that
  # extends parent axes `axis..axis+tdim.size-1` by the corresponding
  # `tdim[i]` factor (= ImageMagick `montage` analog).  Output ndim equals
  # each piece's ndim; the tile axes occupy positions
  # `axis..axis+tdim.size-1`.  Returns a view; call `.to_ca` to materialise.
  #
  # `tdim.product` must equal `list.size`.  For non-uniform pieces along
  # tile axes, use `CArray.mosaic`.
  #
  # Example (parent shape (3, 4), 6-element list, tdim=[2, 3], axis: 0):
  #
  #   CArray.montage([a, b, c, d, e, f], [2, 3], axis: 0)
  #   #=> shape (6, 12) -- 2 rows x 3 cols grid of (3, 4) blocks
  #   #   +-----+-----+-----+
  #   #   |  a  |  b  |  c  |  rows 0..2
  #   #   +-----+-----+-----+
  #   #   |  d  |  e  |  f  |  rows 3..5
  #   #   +-----+-----+-----+
  #
  # 3.0 (post K_AXIS / promote_list / stack rename): renamed from `combine`
  # (= 20-year vocabulary that didn't describe the action).  Positional
  # `at` replaced with `axis:` kwarg for consistency with bind / stack.
  # Parameter order changed from `(tdim, list, at)` to `(list, tdim, axis:)`
  # to align with bind / stack (`list` first).
  # @overload montage(list, tdim, axis: 0, data_type: nil)
  #   Returns a view arranging uniform-shape pieces in a `tdim`-shape
  #   grid that extends parent axes `axis..axis+tdim.size-1` by the
  #   corresponding `tdim[i]` factors. Output `ndim` equals each
  #   piece's `ndim`. `tdim.product` must equal `list.size`. For
  #   non-uniform pieces along tile axes, use `CArray.mosaic`.
  #   @param list [Array<CArray>] pieces to arrange.
  #   @param tdim [Array<Integer>] tile grid shape.
  #   @param axis [Integer] first tile axis in the result.
  #   @param data_type [Symbol, Integer, nil] result `data_type`.
  #   @return [CArray] tiled view.
  #   @raise [ArgumentError] when `list` is empty or `tdim.product !=
  #     list.size`.
  def self.montage (list, tdim, axis: 0, data_type: nil)
    raise ArgumentError, "montage: list must not be empty" if list.empty?
    unless tdim.is_a?(Array) && tdim.size > 0
      raise ArgumentError, "montage: tdim must be a non-empty Array of Integer"
    end
    expected = tdim.inject(1) { |acc, n| acc * n }
    unless expected == list.size
      raise ArgumentError,
            "montage: tdim product (#{expected}) must equal list size (#{list.size})"
    end

    list = CArray.promote_list(list, data_type: data_type)
    parent_shape = list[0].shape
    ntile = tdim.size
    nparent = parent_shape.size
    axis = CArray.normalize_axis(axis, nparent - ntile + 1, "montage")

    s = CArray.stack(list).reshape(*tdim, *parent_shape)   # (K, *) → (*tdim, *)

    # Interleave: tile axis i (= s axis i, i ∈ [0, ntile)) is moved to
    # just before parent axis (axis + i) in s coordinates (= s axis
    # ntile + axis + i).
    perm = []
    nparent.times do |j|
      if j.between?(axis, axis + ntile - 1)
        perm << (j - axis)           # tile axis
      end
      perm << ntile + j              # parent axis
    end
    s = s.transpose(*perm)

    # Merge each (tile[i], parent[axis+i]) pair via reshape.
    new_shape = parent_shape.dup
    ntile.times { |i| new_shape[axis + i] *= tdim[i] }
    s.reshape(*new_shape)
  end

  # Instance-side stack: build a new K-stack from `[self] + others`
  # along the new K axis at position `axis:`.  Always treats `self` as a
  # parent (= even when self is a CAStack, the resulting stack has self
  # as one of its parents, NOT flat-appended into self's parents).
  #
  # For flat-appending into an existing CAStack (= same k_axis, parents
  # extended), use `CAStack#append`.
  #
  # 3.0: high-level Face-aware surface, mirrors `CArray.stack(list, axis:)`.
  # @overload stack(*others, axis: 0, data_type: nil)
  #   Returns a K-stack view built from `[self] + others` along a
  #   new K axis at position `axis`. Always treats `self` as one
  #   parent, even when `self` is a CAStack; use {CAStack#append} to
  #   flat-append into an existing CAStack.
  #   @param others [Array<CArray>] additional parents.
  #   @param axis [Integer] position of the new K axis.
  #   @param data_type [Symbol, Integer, nil] result `data_type`.
  #   @return [CArray] CAStack view.
  #   @raise [ArgumentError] when no `others` are given.
  def stack (*others, axis: 0, data_type: nil)
    raise ArgumentError, "stack: at least one other parent required" if others.empty?
    CArray.stack([self] + others, axis: axis, data_type: data_type)
  end

  # Split self along a single axis into an Array of (ndim-1)-D slices, each
  # a writable CABlock view.  The exact inverse of CArray.stack -- split's
  # slices are all the same shape, so they round-trip back through stack:
  #
  #   CArray.stack(a.split(axis: k), axis: k) == a
  #
  #   a = CA_INT([[1,2,3], [4,5,6]])
  #   a.split(axis: 0)   #=> [ <[1,2,3]>, <[4,5,6]> ]      (row views)
  #   a.split(axis: 1)   #=> [ <[1,4]>, <[2,5]>, <[3,6]> ] (column views)
  #
  # 3.0 breaking:
  #   - returns a Ruby Array of views (was an object CArray), so it
  #     round-trips with CArray.stack (which takes an Array)
  #   - +axis:+ takes a single Integer (the multi-axis Array form, which
  #     returned an N-D object grid, is no longer accepted)
  #   - pieces are CABlock views, NOT copies; writing through a piece
  #     mutates +self+.  Chain +.copy+ / +.to_ca+ for independent entities.
  # @overload split(axis:)
  #   Returns an Array of `(ndim-1)`-D writable CABlock views obtained
  #   by splitting `self` along `axis`. Inverse of `CArray.stack`.
  #   Slices share storage with `self`; chain `.copy` for independent
  #   entities.
  #   @param axis [Integer] axis to split along.
  #   @return [Array<CArray>] one slice per index along `axis`.
  #   @raise [ArgumentError] when `axis` is not a single Integer.
  def split (axis:)
    if axis.is_a?(Array)
      raise ArgumentError, "split: axis must be a single Integer"
    end
    k = normalize_axis(axis, "split")
    (0...shape[k]).map do |i|
      idx = [nil] * ndim
      idx[k] = i
      self[*idx]
    end
  end

end

# CAStack.new(list, axis: 0) is implemented in C (ext/ca_obj_stack.c
# rb_ca_stack_s_new): it overrides Class#new to inspect Face homogeneity
# and (when applicable) re-wrap the raw CAStack via ca_face_lift.  The
# Ruby class only adds the #append instance method below.
class CAStack
  # Flat-append `others` into self's parents, preserving the receiver's
  # k_axis.  Returns a new CAStack with the combined parents list.
  #
  # Distinct from `CArray#stack(other)` which always treats self as a
  # single parent of a new K-stack -- here, the existing K-stack is
  # extended in place.
  #
  # Example:
  #   s = CArray.stack([a, b], axis: 1)   # 2-parent stack, k_axis=1
  #   s.append(c, d)                       # 4-parent stack, k_axis=1
  # @overload append(*others)
  #   Returns a new CAStack whose parents are `self.parents + others`,
  #   preserving `self.k_axis`. Distinct from `CArray#stack`, which
  #   always treats `self` as a single parent of a new K-stack.
  #   @param others [Array<CArray>] extra parents to append.
  #   @return [CAStack]
  #   @raise [ArgumentError] when no `others` are given.
  def append (*others)
    raise ArgumentError, "append: at least one parent required" if others.empty?
    CArray.stack(self.parents + others, axis: self.k_axis)
  end
end
