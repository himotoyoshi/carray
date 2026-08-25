# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_copy.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Copy and conversion

  # @overload copy
  #   Returns a fresh entity CArray with the same shape, `data_type`,
  #   element values, and mask state as `self`. Always allocates and
  #   copies, even when `self` is already an entity.
  #
  #   Use `copy` when you need an array you own and can mutate
  #   without affecting any source.
  #   @return [CArray] independent entity.
  #   @example A view's copy is independent of its source
  #     a = CArray.float64(4).seq
  #     v = a[1..2]
  #     b = v.copy
  #     b[0] = 99
  #     a   # => [0.0, 1.0, 2.0, 3.0]   # untouched
  def copy; end

  # @overload to_ca(writable: false)
  #   Returns `self` as a CArray, doing the least work possible.
  #
  #   For a CArray (entity or data view), `to_ca` returns `self`
  #   unchanged — **no copy is made**. Use {#copy} when you need an
  #   independent owned array. Mutating the result of `to_ca` may
  #   therefore mutate the source.
  #
  #   `to_ca` is the universal "give me a CArray" entry point. It is
  #   also defined on `Array` / `Range` / `Enumerator::ArithmeticSequence`
  #   (each builds a 1-D CArray) and on lazy views (`CAMonOp`, `CABinOp`,
  #   …) where it forces evaluation into a fresh entity.
  #
  #   Because it converts as cheaply as it can — sharing storage where it
  #   can, copying where it must — the result alone does not tell you
  #   whether writes to it reach the source. `writable: true` is how a
  #   caller states that they do have to: an implementation that can only
  #   hand back a detached copy raises instead of returning one, so a
  #   write is never swallowed silently. For a CArray, `self` shares its
  #   storage by construction, so the only refusal here is a read-only
  #   receiver. This is the contract {CArray.wrap_writable} duck-types on.
  #   @param writable [Boolean] when true, demand a result whose writes
  #     reach the source.
  #   @return [CArray] `self` (no copy).
  #   @raise [RuntimeError] when `writable: true` and `self` is read-only.
  def to_ca(writable: false); end

  # @overload template
  #   Returns a freshly allocated CArray with the same shape and
  #   `data_type` as `self`, filled with zeros. The new array is an
  #   entity and carries no mask.
  #   @return [CArray]
  # @overload template(data_type, bytes: 0)
  #   Returns a freshly allocated CArray with the same shape as
  #   `self` but the given `data_type`, filled with zeros.
  #   @param data_type [Symbol] target element type
  #     (e.g. `:int32`, `:float64`, `:fixlen`).
  #   @param bytes [Integer] element byte size; required for
  #     `:fixlen`, ignored for numeric types.
  #   @return [CArray]
  # @overload template { value }
  #   With a 0-arity block, fills every element of the result with
  #   the block's return value (broadcast). Equivalent to
  #   `template.tap { |t| t[] = value }`.
  #   @yieldreturn [Object] value to broadcast to every element.
  #   @return [CArray]
  # @overload template { |*idx| ... }
  #   With a block of arity > 0, calls the block once per cell with
  #   the multi-dimensional index `*idx` and stores the result.
  #   @yieldparam idx [Array<Integer>] per-axis indices.
  #   @yieldreturn [Object]
  #   @return [CArray]
  def template(*, **, &block); end

  # @!endgroup
end
