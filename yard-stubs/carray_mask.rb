# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_mask.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Masking

  # @overload has_mask?
  #   Returns `true` if `self` has a mask array attached. Note that a
  #   present mask may still have every entry set to "not masked".
  #   @return [Boolean]
  def has_mask?; end

  # @overload any_masked?
  #   Returns `true` if at least one element of `self` is masked.
  #   @return [Boolean]
  def any_masked?; end

  # @overload all_masked?
  #   Returns `true` if every element of `self` is masked.
  #   @return [Boolean]
  def all_masked?; end

  # @overload value
  #   Returns a new view that exposes the underlying data of `self`,
  #   bypassing the mask. The returned view itself cannot carry a
  #   mask (`value_array? == true`).
  #
  #   Use this to read or write the data slot of masked elements.
  #   @return [CArray]
  def value; end

  # @overload mask
  #   Returns a new boolean view of the mask state of `self`. Each
  #   element is `1` where `self` is masked and `0` where it is not.
  #   The returned view itself cannot carry a mask.
  #
  #   Returns `0` (Integer) if `self` has no mask array attached.
  #   @return [CArray, Integer]
  def mask; end

  # @overload mask=(new_mask)
  #   Sets the mask array of `self` to `new_mask`. Allocates the mask
  #   array first if `self` does not yet have one. Cannot be called on
  #   a value array or a mask array.
  #   @param new_mask [CArray, Boolean, Integer] mask values. A
  #     non-CArray value is broadcast and stored elementwise; a CArray
  #     of any type is coerced to boolean.
  #   @return [Object] `new_mask`.
  def mask=(new_mask); end

  # @overload is_masked
  #   Returns a new boolean CArray of the same shape as `self`, with
  #   `1` at masked positions and `0` elsewhere.
  #   @return [CArray]
  def is_masked; end

  # @overload is_not_masked
  #   Returns a new boolean CArray of the same shape as `self`, with
  #   `1` at not-masked positions and `0` elsewhere.
  #   @return [CArray]
  def is_not_masked; end

  # `unmask` clears a mask by *supplying values*. The value source is
  # either a constant (the positional `fill_value`) or a scan `method:`
  # that derives values from neighbouring valid cells (mask gap-fill).
  # The two are mutually exclusive: passing both raises `ArgumentError`.
  #
  # @overload unmask
  #   Clears the mask state of every element of `self`, leaving the
  #   stored data values untouched. Mutates `self`.
  #   @return [self]
  # @overload unmask(fill_value)
  #   Clears the mask state and overwrites the data at previously
  #   masked positions with `fill_value`. Mutates `self`.
  #   @param fill_value [Object] value to store at each previously
  #     masked position. Cast to `self.data_type`.
  #   @return [self]
  # @overload unmask(method:, axis: nil)
  #   Fills masked cells in place from neighbouring valid cells along
  #   `axis` (gap-fill), then clears the filled cells' mask. Mutates
  #   `self`. Leading (`:forward`) / trailing (`:backward`) runs of
  #   masked cells with no value to carry, and cells outside the valid
  #   range (`:linear`), stay masked — so a mask may remain.
  #   @param method [Symbol] fill rule:
  #     `:forward` / `:ffill` carries the last valid value forward;
  #     `:backward` / `:bfill` carries the next valid value backward
  #     (defined for every data_type — numeric, complex, bool, object,
  #     fixlen, and Face); `:linear` interpolates each masked cell
  #     linearly by index from the two bracketing valid cells (numeric
  #     data_type, or a time Face — `CATime` / `CATimedelta` interpolate
  #     through their own `linear_fetch`, so the filled values stay on the
  #     array's unit and are rounded to it).
  #   @param axis [Integer, nil] scan axis (single axis). `nil` flattens.
  #   @return [self]
  def unmask(*, method: nil, axis: nil); end

  # `strip_mask` is the copy form of `unmask`: it returns a new array
  # rather than mutating `self`, supplying values either from a constant
  # `fill_value` or a scan `method:`. The two are mutually exclusive.
  #
  # @overload strip_mask(fill_value)
  #   Returns a new array with the same shape and `data_type` as
  #   `self`, with no mask attached, and `fill_value` substituted at
  #   positions that were masked in `self`. `self` is not modified.
  #
  #   Replaces the removed `unmask_copy(fill)` from 2.x.
  #   @param fill_value [Object] value to substitute at masked
  #     positions. Cast to `self.data_type`.
  #   @return [CArray]
  # @overload strip_mask(method:, axis: nil)
  #   Returns a new array with masked cells filled from neighbouring
  #   valid cells along `axis` (gap-fill). `self` is not modified.
  #   Residual (leading / trailing / out-of-range) masked cells that
  #   cannot be filled stay masked in the returned array.
  #   @param method [Symbol] fill rule: `:forward` / `:ffill`,
  #     `:backward` / `:bfill` (any data_type), or `:linear` (numeric or a
  #     time Face). See {#unmask} for the full description.
  #   @param axis [Integer, nil] scan axis (single axis). `nil` flattens.
  #   @return [CArray]
  def strip_mask(*, method: nil, axis: nil); end

  # `first` / `last` are the reduction sibling of the `:forward` / `:backward`
  # hold (see {#unmask}): instead of filling a whole fiber they return the one
  # first / last **valid** (unmasked) value. For an unmasked array they
  # degrade to the first / last element. Works for every data_type.
  #
  # @overload first(axis: nil, keep_axis: false)
  #   Returns the first valid (unmasked) value along `axis`, skipping masked
  #   cells. Identity-less: a fiber with no valid cell (all masked, or empty)
  #   yields UNDEF. To substitute a default instead, complete at the call
  #   site — `a.first(axis: 0).strip_mask(v)`.
  #   @param axis [Integer, Array<Integer>, nil] reduce axis / axes; `nil`
  #     reduces the whole array to a scalar.
  #   @param keep_axis [Boolean] keep the reduced axis as a size-1 axis.
  #   @return [Object, CArray] a scalar for a full reduce (UNDEF if no valid
  #     cell), otherwise a reduced CArray.
  def first(axis: nil, keep_axis: false); end

  # @overload last(axis: nil, keep_axis: false)
  #   Returns the last valid (unmasked) value along `axis` (the backward
  #   counterpart of {#first}).
  #   @param axis [Integer, Array<Integer>, nil] reduce axis / axes; `nil`
  #     reduces the whole array to a scalar.
  #   @param keep_axis [Boolean] keep the reduced axis as a size-1 axis.
  #   @return [Object, CArray] a scalar for a full reduce (UNDEF if no valid
  #     cell), otherwise a reduced CArray.
  def last(axis: nil, keep_axis: false); end

  # @overload invert_mask
  #   Flips the mask state of every element of `self` in place
  #   (masked ↔ not masked). Mutates `self`.
  #   @return [self]
  def invert_mask; end

  # @overload inherit_mask(*others)
  #   Sets the mask of `self` to the logical OR of the current mask
  #   of `self` and the masks of each array in `others`. Mutates
  #   `self`.
  #   @param others [Array<CArray>] arrays whose mask states are
  #     OR-ed into `self`. Non-CArray arguments are ignored.
  #   @return [self]
  def inherit_mask(*others); end

  # @overload inherit_mask_replace(*others)
  #   Sets the mask of `self` to the logical OR of the masks of the
  #   arrays in `others` only (the current mask of `self` is
  #   discarded, in contrast to {#inherit_mask}). Mutates `self`.
  #   @param others [Array<CArray>] arrays whose mask states form the
  #     new mask of `self`.
  #   @return [self]
  def inherit_mask_replace(*others); end

  # @overload count_masked
  #   Returns the total number of masked elements in `self`.
  #   @return [Integer]
  # @overload count_masked(axis:)
  #   Returns the per-slice count of masked elements along the given
  #   axis or axes. The result is an int64 CArray with `axis` removed
  #   from `shape`.
  #   @param axis [Integer, Array<Integer>] axis or axes to reduce.
  #   @return [CArray] int64 CArray.
  def count_masked(*, **); end

  # @overload count_not_masked
  #   Returns the total number of not-masked elements in `self`.
  #   @return [Integer]
  # @overload count_not_masked(axis:)
  #   Returns the per-slice count of not-masked elements along the
  #   given axis or axes. The result is an int64 CArray with `axis`
  #   removed from `shape`.
  #   @param axis [Integer, Array<Integer>] axis or axes to reduce.
  #   @return [CArray] int64 CArray.
  def count_not_masked(*, **); end

  # @!endgroup

  # @!group Masking

  # @overload mask_eq(v)
  #   Returns a copy of `self` with every element equal to `v` masked.
  #   In-place equivalent: `ca[:eq, v] = UNDEF`.
  #
  #   Replaces the removed `maskout(v)` from 2.x.
  #   @param v [Object] value to mask. Cast to `self.data_type`.
  #   @return [CArray]
  def mask_eq(v); end

  # @overload mask_invalid
  #   Returns a copy of `self` with every NaN or Inf element masked.
  #   For integer or boolean arrays this is a plain copy (no element
  #   is invalid by `is_finite.not` semantics).
  #   In-place equivalent: `ca[:is_invalid] = UNDEF`.
  #   @return [CArray]
  def mask_invalid; end

  # @overload mask_where(key, *args)
  #   Returns a copy of `self` with elements matching the given indexer
  #   predicate masked. Mirrors the indexer key set:
  #
  #   ```ruby
  #   ca.mask_where(:lt, v)      # same as: copy then ca[:lt, v] = UNDEF
  #   ca.mask_where(:is_invalid) # same as: copy then ca[:is_invalid] = UNDEF
  #   ca.mask_where(bool_array)  # same as: copy then ca[bool_array] = UNDEF
  #   ```
  #
  #   At least one argument is required. For in-place mutation use the
  #   indexer idiom directly: `ca[key, *args] = UNDEF`.
  #   @param key [Symbol, CArray] indexer key or boolean condition array.
  #   @param args [Array] additional arguments required by the predicate.
  #   @return [CArray]
  def mask_where(*args); end

  # @!endgroup

  class << self
    # @!group Masking

    # @overload guard_undef(*values, fill_value: UNDEF)
    #   Returns `fill_value` immediately if any element of `values` is
    #   `UNDEF`; otherwise yields all `values` to the block and returns
    #   the block's result.
    #
    #   ```ruby
    #   CArray.guard_undef(a, b) { |x, y| x / y }    # UNDEF if a or b masked
    #   CArray.guard_undef(v, fill_value: 0.0) { |x| Math.sqrt(x) }
    #   ```
    #
    #   @param values [Array<Object>] scalar values to test.
    #   @param fill_value [Object] value returned on short-circuit.
    #     Defaults to `UNDEF`.
    #   @yieldparam values [Array<Object>] the non-UNDEF values.
    #   @yieldreturn [Object] computation result.
    #   @return [Object]
    def guard_undef(*values, fill_value: UNDEF); end

    # @!endgroup
  end
end
