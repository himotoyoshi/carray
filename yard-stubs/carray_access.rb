# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_access.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.
#
# The indexer surface (`[]` / `[]=`) is large; the per-form detail lives in
# the user guides (see the @see links) rather than being duplicated here.

class CArray
  # @!group Indexing and slicing

  # @overload [](*index)
  #   Returns a view of `self` (or a single element) selected by one
  #   `index` per axis.  Every array-returning form is a view onto the
  #   original storage — writing through it reaches the source.
  #
  #   Accepted per-axis index forms:
  #   - Integer — one position (negative counts from the end); an
  #     all-Integer index returns the single element (masked -> UNDEF).
  #   - `nil` — the whole axis.
  #   - Range — a contiguous (or stepped, via a stepped Range) sub-range.
  #   - boolean CArray — masked selection along that axis.
  #   - Integer CArray — fancy gather (index array); shape follows the
  #     index array.
  #   - `:_` — newaxis: insert a size-1 axis at this position.
  #   - `:*` / `:%` — repeat / tiling sugar.
  #   - `:>` — slab axis: wrap the result in a `CASlabIterator`.
  #   - a member name Symbol — project a struct field (see `CARecord`).
  #
  #   A single flat Integer (fewer indices than `ndim`) addresses the
  #   array in row-major flat order.
  #   @param index [Array<Integer, Range, nil, CArray, Symbol>] one entry
  #     per axis (or a single flat address).
  #   @return [CArray, Object] a view for a slicing form, or the element
  #     value (or `UNDEF` if masked) for an all-scalar index.
  #   @raise [IndexError] on an out-of-range index or an unrecognised form.
  #   @see file:docs/drafts/02_indexing_and_slicing.md Indexing and slicing
  #   @see file:docs/drafts/16_indexer_reference.md Indexer reference
  def [](*index); end

  # @overload []=(*index, value)
  #   Sets the cells of `self` selected by `index` (same per-axis forms as
  #   {#[]}) to `value`.  `value` may be a scalar (broadcast), an Array, or
  #   a CArray whose element count matches the selection; assigning `UNDEF`
  #   masks the selected cells.
  #
  #   Assignment through a slab iterator (`:>`) is not supported — use a
  #   block index (e.g. `ca[range, nil] = val`) or `each_slab`.
  #   @param index [Array<Integer, Range, nil, CArray, Symbol>] one entry
  #     per axis (or a single flat address).
  #   @param value [Object, Array, CArray] the value(s) to store, or
  #     `UNDEF` to mask.
  #   @return [Object] `value`.
  #   @raise [IndexError] on an out-of-range index or an unsupported form.
  #   @see file:docs/drafts/16_indexer_reference.md Indexer reference
  def []=(*index, value); end

  # @!endgroup

  # @!group Indexing and slicing

  # @overload fill(value)
  #   Sets every element of `self` to `value` and clears any mask.
  #   @param value [Object] the fill value.
  #   @return [self]
  def fill(value); end

  # @overload fill_copy(value)
  #   Returns a copy of `self` with every element set to `value`.
  #   @param value [Object] the fill value.
  #   @return [CArray] the filled copy.
  def fill_copy(value); end

  # @!endgroup

  # @!group Index and address conversion

  # @overload addr2index(addr)
  #   Unravels a flat row-major address into per-axis indices, sized by
  #   `self.shape`.  With an Integer `addr` returns N Integers; with a
  #   CArray of addresses returns N CArrays of the same shape as `addr`
  #   (mask propagated per cell).  In both cases the return is a Ruby
  #   Array of length `self.ndim`, so `i, j = ca.addr2index(x)` unpacks
  #   uniformly for scalar and vector inputs.
  #   @param addr [Integer, CArray] a flat address in `0...elements`,
  #     or a CArray of such addresses (arbitrary shape).
  #   @return [Array<Integer>, Array<CArray>] one entry per axis.
  #   @raise [ArgumentError] when any `addr` is out of range.
  def addr2index(addr); end

  # @overload index2addr(*index)
  #   Folds per-axis indices into flat row-major address(es), using
  #   `self.shape`.  With all-Integer indices returns a single Integer;
  #   when any index is a CArray, returns a CArray of addresses whose
  #   shape follows the first non-scalar input (other non-scalar inputs
  #   must match that shape).  Mask propagates from the inputs.
  #   @param index [Array<Integer, CArray>] one entry per axis.
  #   @return [Integer, CArray] the flat address(es).
  #   @raise [IndexError] on an out-of-range index.
  #   @raise [ArgumentError] on shape mismatch between non-scalar inputs.
  def index2addr(*index); end

  # @overload addr2index(addr, shape:)
  #   Class-form of {#addr2index} that takes an explicit `shape:` rather
  #   than reading it from a receiver.  Useful for coordinate arithmetic
  #   without allocating a template CArray.
  #   @param addr [Integer, CArray] a flat address or a CArray of them.
  #   @param shape [Array<Integer>] the row-major shape defining the grid.
  #   @return [Array<Integer>, Array<CArray>] one entry per axis.
  #   @raise [ArgumentError] when any `addr` is out of range or `shape:`
  #     is missing.
  def self.addr2index(addr, shape:); end

  # @overload index2addr(*index, shape:)
  #   Class-form of {#index2addr}.
  #   @param index [Array<Integer, CArray>] one entry per axis.
  #   @param shape [Array<Integer>] the row-major shape defining the grid.
  #   @return [Integer, CArray] the flat address(es).
  #   @raise [ArgumentError] on out-of-range index, shape mismatch, or
  #     missing `shape:`.
  def self.index2addr(*index, shape:); end

  # @overload normalize_index(idx)
  #   Returns a canonical form of the index array `idx` classified against
  #   `self`'s shape (scalars normalised, `nil` for whole axes, `[start,
  #   count, step]` for blocks).  Used to inspect how an index resolves.
  #   @param idx [Array] the raw index spec.
  #   @return [Array] the normalised per-axis index.
  def normalize_index(idx); end

  # @!endgroup
end
