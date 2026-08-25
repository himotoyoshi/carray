# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_slab.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.
#
# The slab-iteration family walks `self` in slabs (sub-arrays) taken along
# a chosen set of axes.  See the @see links for the full walkthrough.

class CArray
  # @!group Iteration

  # @overload each_slab(axis:)
  #   Yields each slab of `self` (a view along the axes NOT in `axis`) to
  #   the block and returns `self`.  The slab is a live view valid only
  #   for the duration of the block — capturing it across iterations sees
  #   the last slab's data.
  # @overload each_slab(axis:)
  #   Returns an Enumerator when no block is given.
  #   @param axis [Integer, Array<Integer>, nil] the slab axis or axes
  #     (`nil` = the whole view as a single slab).
  #   @return [self, Enumerator]
  #   @see file:docs/SlabIterator.md SlabIterator
  #   @see file:docs/drafts/11_slab_iteration.md Slab iteration
  def each_slab(axis:); end

  # @overload map_slab(axis:, data_type: nil)
  #   Returns a new CArray built by replacing each slab of `self` with the
  #   block's result.  The block receives the slab view and must return a
  #   value of the same shape as the slab (a CArray or scalar); the results
  #   are written into the output at the same positions.
  #   @param axis [Integer, Array<Integer>, nil] the slab axis or axes.
  #   @param data_type [Symbol, Integer, Class, nil] output data type
  #     (defaults to `self`'s data type).
  #   @return [CArray]
  #   @raise [ArgumentError] when the block result's shape does not match
  #     the slab.
  #   @see file:docs/SlabIterator.md SlabIterator
  def map_slab(axis:, data_type: nil); end

  # @overload reduce_slab(axis:, data_type: nil)
  #   Per-slab form (no `init:`): the block receives each slab view and
  #   returns a scalar; the scalars fill an output CArray with the slab
  #   axes collapsed.  Returning a CArray from the block is an error (use
  #   `slab[0]`, `slab.sum`, etc. to extract a scalar).
  # @overload reduce_slab(axis:, init:, data_type: nil)
  #   Per-element form (`init:` given): the block receives `(acc, x)` for
  #   each element of the slab and returns the new accumulator; the final
  #   accumulator per slab fills the output.
  #   @param axis [Integer, Array<Integer>, nil] the slab axis or axes.
  #   @param init [Object] the initial accumulator (selects the
  #     per-element form).
  #   @param data_type [Symbol, Integer, Class, nil] output data type.
  #   @return [CArray] the reduced array (slab axes collapsed).
  #   @see file:docs/SlabIterator.md SlabIterator
  def reduce_slab(axis:, init: nil, data_type: nil); end

  # @!endgroup
end
