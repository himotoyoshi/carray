# Composition methods cheat sheet (CArray 3.0 surface)
#
# The three class methods `meld` / `stack` / `montage` form a uniform-input
# view-default surface; their ragged eager counterparts `concatenate` / --
# / `mosaic` accept non-uniform pieces.
#
# This file holds the eager ragged family (`concatenate` / `mosaic`) and
# the 1-D column bundler (`tabulate`).  `split` (the inverse of stack) lives
# in carray/stack.rb; the sub-region copy pair (`paste` / `crop`) lives in
# carray/basics.rb; the shape-edit helpers (`resize`, `insert_block` /
# `delete_block`) live in carray/methods/.  The CAStack view-default trio
# (`stack` / `meld` / `montage`, plus `CArray#stack` and `CAStack#append`)
# lives in carray/stack.rb.  The cheat sheet below covers the whole family.
#
#                       | view (same dtype)      | eager (auto-cast)
#   -------------------+------------------------+-----------------------
#   concat existing    | meld  (CAMeld view)    | concatenate (materialised)
#   axis (ndim same)   |                        |
#   -------------------+------------------------+-----------------------
#   add new axis       | stack (CAStack view)   | (= ragged impossible)
#   (ndim grows)       |                        |
#   -------------------+------------------------+-----------------------
#   tile grid          | montage                | mosaic (materialised)
#   (ndim same, axes   |                        |
#   extend by tdim)    |                        |
#
# `meld` (CAMeld view) is the unified surface for concatenation along an
# existing axis: it handles both uniform and ragged pieces and returns a
# CAMeld view.  Parents must agree on data_type — cast beforehand or use
# `concatenate` (eager, auto-casts).
#
# Vocabulary:
#   meld    = melt + weld; pieces dissolve their boundaries along the
#             named axis and are regarded as one; returns a CAMeld view
#   stack   = K parents pushed onto a new K axis (CAStack view)
#   montage = uniform tiles arranged in a regular grid (ImageMagick)
#   concatenate = 1-axis concat, eager materialised copy with auto-cast
#   mosaic  = irregular pieces fitted into a grid (art-form analog)
#
# Examples (a, b, c are each shape [3, 4]):
#
#   CArray.meld([a, b, c])                        #=> view, shape (9, 4)
#   CArray.meld([a, b, c], axis: 1)               #=> view, shape (3, 12)
#   CArray.meld([a, b, c]).to_ca                  #=> eager CArray, shape (9, 4)
#   CArray.stack([a, b, c])                       #=> view, shape (3, 3, 4)   (K outermost)
#   CArray.stack([a, b, c], axis: -1)             #=> view, shape (3, 4, 3)   (RGB pattern)
#   CArray.montage([a, b, c, d], [2, 2], axis: 0) #=> view, shape (6, 8) (2x2 image tile)
#
#   # data_type is a kwarg (= 3.0 breaking); omitted = result_type auto-infer
#   CArray.meld([a, b, c], axis: 0, data_type: :float64)
#   CArray.meld([a, b, c])                        # data_type inferred
#
# `tabulate` bundles a list of 1-D arrays into a 2-D table (one column
# each).  Block-matrix assembly is `mosaic`; vertical stacking of 2-D
# tables is `concatenate(axis: 0)`.  (The old `join` / block-style
# helper was retired in 3.0 -- its column-major nesting was confusing and
# `mosaic` covers block assembly correctly.)
#
# Known limitation: scalar indexing on a CAStack-rooted view drops ndim
# and triggers a full materialise fallback.  Use range indexing (e.g.
# `meld(...)[k..k, nil]` instead of `meld(...)[k, nil]`) for partial-use
# perf, or `.to_ca` upfront to materialise eagerly.

class CArray

  # CArray#paste / #crop (sub-region copy) live in carray/basics.rb.

  # ---------------------------------------------------------------- eager ragged 2

  # @overload concatenate(list, axis: 0, data_type: nil)
  #   Returns `list` concatenated along a single existing axis. Eager
  #   (returns a fresh CArray) and accepts non-uniform pieces (varying
  #   sizes along the `axis`); non-tile axes must agree across pieces.
  #
  #   Use `CArray.meld` for the uniform-shape view-default counterpart.
  #
  #   @param list [Array<CArray>] pieces to concatenate.
  #   @param axis [Integer] axis to concatenate along.
  #   @param data_type [Symbol, Integer, nil] result `data_type`;
  #     inferred via `result_type` when `nil`.
  #   @return [CArray] fresh CArray with per-piece `axis` sizes summed.
  #   @raise [ArgumentError] when `list` is empty or piece shapes are
  #     inconsistent.
  def self.concatenate (list, axis: 0, data_type: nil)
    raise ArgumentError, "concatenate: list must not be empty" if list.empty?
    __ragged_paste(list, [list.size], axis, data_type)
  end

  # @overload concatenate(*others, axis: 0, data_type: nil)
  #   Instance form of {CArray.concatenate}: returns `[self, *others]`
  #   concatenated along `axis` as a fresh CArray. Eager auto-cast
  #   counterpart of `#meld` (view).
  #
  #   @param others [Array<CArray>] additional pieces.
  #   @param axis [Integer] axis to concatenate along.
  #   @param data_type [Symbol, Integer, nil] result `data_type`;
  #     inferred via `result_type` when `nil`.
  #   @return [CArray] fresh CArray.
  #   @raise [ArgumentError] when no `others` are given.
  def concatenate (*others, axis: 0, data_type: nil)
    raise ArgumentError, "concatenate: at least one other array required" if others.empty?
    CArray.concatenate([self, *others], axis: axis, data_type: data_type)
  end

  # @overload mosaic(list, tdim, axis: 0, data_type: nil)
  #   Returns `list` tiled into an N-D grid layout described by
  #   `tdim`. Eager (returns a fresh CArray), accepts non-uniform
  #   sizes along the tile axes with block-matrix consistency
  #   (row-by-row / column-by-column agreement).
  #
  #   @param list [Array<CArray>] pieces to tile; length must equal
  #     the product of `tdim`.
  #   @param tdim [Array<Integer>] tile grid shape.
  #   @param axis [Integer] first tile axis in the result.
  #   @param data_type [Symbol, Integer, nil] result `data_type`;
  #     inferred when `nil`.
  #   @return [CArray] fresh CArray with tile axes extended by summed
  #     per-tile sizes.
  #   @raise [ArgumentError] when `list` is empty, `tdim` is
  #     ill-formed, or piece shapes violate block-matrix consistency.
  def self.mosaic (list, tdim, axis: 0, data_type: nil)
    raise ArgumentError, "mosaic: list must not be empty" if list.empty?
    unless tdim.is_a?(Array) && tdim.size > 0
      raise ArgumentError, "mosaic: tdim must be a non-empty Array of Integer"
    end
    expected = tdim.inject(1, :*)
    unless expected == list.size
      raise ArgumentError,
            "mosaic: tdim product (#{expected}) must equal list size (#{list.size})"
    end
    __ragged_paste(list, tdim, axis, data_type)
  end

  # Shared eager paste-loop helper (= ex-`combine` paste implementation,
  # preserved verbatim for concatenate / mosaic).  Returns a fresh CArray of
  # shape obtained by tiling `list` over `tdim` starting at `axis`, with
  # per-piece dim sizes summed along each tile axis (= block-matrix
  # consistency required across rows / columns).
  def self.__ragged_paste (list, tdim, axis, data_type)
    list = CArray.promote_list(list, data_type: data_type)
    # promote_list has already enforced homogeneity (= common data_type, and
    # for Face elements: same Face class + portable + state-compatible).  So,
    # mirroring CArray.stack, paste at the storage level and re-wrap the
    # result with face_lift, rather than special-casing data_class / DATA_SIZE
    # here (= which only ever handled CARecord and silently corrupted plain
    # fixlen / numeric Faces by leaving bytes nil).
    face_parent = list[0].face? ? list[0] : nil
    if face_parent
      list = list.map { |x| s = x; s = s.parent while s.face?; s }
    end
    data_type = list[0].data_type
    bytes     = (data_type == :fixlen) ? list[0].bytes : nil
    # promote_list guarantees a non-empty list of CArrays, so the reference
    # shape is simply the first element (a CScalar carries shape [1], so a
    # leading scalar is fine; the scalar-expansion pass below broadcasts it).
    ref  = list[0]
    dim   = ref.shape
    ndim  = ref.ndim
    tndim = tdim.size
    axis = CArray.normalize_axis(axis, ndim - tndim + 1, "concatenate/mosaic")

    list = list.map do |x|
      if x.scalar?
        rdim = dim.clone
        rdim[axis] = :%
        x = x[*rdim]
      end
      x
    end

    block = CArray.object(*tdim).tap { |a| a[] = list }
    # Measure the per-tile-axis sizes from the representative line (= all
    # other tile coords 0).  Tile axes may be ragged, but every piece must
    # then be block-matrix consistent (= same size along a tile axis as its
    # line) and must agree with the reference on each non-tile axis.
    edim = tdim.clone
    tile_sizes = Array.new(tndim) { [] }
    offset = Array.new(tndim) { [] }
    probe  = Array.new(tndim, 0)
    tndim.times do |i|
      edim[i] = 0
      probe.map! { 0 }
      probe[i] = nil
      block[*probe].each do |e|
        offset[i] << edim[i]
        tile_sizes[i] << e.shape[axis + i]
        edim[i] += e.shape[axis + i]
      end
    end
    block.each_with_index do |item, *tidx|
      unless item.ndim == ndim
        raise ArgumentError,
              "concatenate/mosaic: piece at tile #{tidx.inspect} has ndim " \
              "#{item.ndim} (expected #{ndim})"
      end
      ndim.times do |d|
        i = d - axis
        on_tile  = (i >= 0 && i < tndim)
        expected = on_tile ? tile_sizes[i][tidx[i]] : dim[d]
        unless item.shape[d] == expected
          raise ArgumentError,
                "concatenate/mosaic: piece at tile #{tidx.inspect} has " \
                "#{on_tile ? 'tile' : 'non-tile'} axis #{d} size " \
                "#{item.shape[d]} (expected #{expected}); pieces must agree " \
                "on non-tile axes and be block-matrix consistent along tile axes"
        end
      end
    end
    newdim = dim.clone
    newdim[axis, tndim] = edim
    obj = CArray.new(data_type, newdim, bytes: bytes)
    idx = newdim.map { 0 }
    block.each_with_index do |item, *tidx|
      (axis...axis + tndim).each_with_index do |d, i|
        idx[d] = offset[i][tidx[i]]
      end
      obj.paste(idx, item)
    end
    obj = obj.face_lift(face_parent) if face_parent
    obj
  end
  private_class_method :__ragged_paste

  # ---------------------------------------------------------------- tabulate

  # @overload tabulate(columns, data_type: nil)
  #   Returns a 2-D table assembled from a list of column blocks,
  #   coerced to a common `data_type`. Eager (returns a fresh, owned
  #   CArray) -- the point is to materialise a typed table, not a view.
  #
  #   Each entry is a 1-D array (one column, length L) or a 2-D array
  #   (a block of `L x k` columns). All entries must share the same
  #   length L; `tabulate` does not pad ragged lengths. Column counts
  #   may differ: entries are concatenated along the column axis, so
  #   a 1-column, a 3-column and a 2-column block produce a 6-column
  #   table. The result `data_type` is inferred (`result_type` of the
  #   entries) unless `data_type` is given.
  #
  #   For block-matrix assembly use `mosaic`; to stack 2-D tables
  #   vertically use `concatenate(axis: 0)`.
  #
  #   @param columns [Array<CArray>] 1-D columns and/or 2-D column
  #     blocks, all of equal length `L`.
  #   @param data_type [Symbol, Integer, nil] result `data_type`;
  #     inferred when `nil`.
  #   @return [CArray] 2-D CArray of shape `(L, total column count)`.
  #   @raise [ArgumentError] when `columns` is empty, entries are
  #     not 1-D or 2-D CArrays, or row counts disagree.
  #   @example
  #     c1 = CA_INT([1, 2, 3])
  #     c2 = CA_DOUBLE([4.5, 5.5, 6.5])
  #     CArray.tabulate([c1, c2])                      # float64 (3, 2)
  #     CArray.tabulate([c1, c2], data_type: :int32)   # int32 (3, 2)
  def self.tabulate (columns, data_type: nil)
    raise ArgumentError, "tabulate: columns must not be empty" if columns.empty?
    blocks = columns.map do |c|
      unless c.is_a?(CArray) && (c.ndim == 1 || c.ndim == 2)
        raise ArgumentError, "tabulate: each column must be a 1-D or 2-D CArray"
      end
      c.ndim == 1 ? c[nil, :_] : c          # promote a bare column to (L, 1)
    end
    len = blocks[0].shape[0]
    blocks.each_with_index do |b, i|
      unless b.shape[0] == len
        raise ArgumentError,
              "tabulate: all columns must have equal length (row count) " \
              "(column 0 has length #{len}, column #{i} has length " \
              "#{b.shape[0]}); tabulate does not pad ragged lengths"
      end
    end
    # Equal-length blocks, ragged column counts -> concatenate along the
    # column axis with a common (coerced or inferred) data_type.
    concatenate(blocks, axis: 1, data_type: data_type)
  end

  # CArray#split (the inverse of CArray.stack) lives in carray/stack.rb,
  # next to stack.  CArray#resize / #insert_block / #delete_block live in
  # carray/methods/ (resize.rb, insert_block.rb), autoloaded.

end
