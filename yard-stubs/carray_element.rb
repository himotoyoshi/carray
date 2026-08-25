# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_element.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Element access
  #
  # `elem_*` methods are low-level single-cell operations. They
  # accept `idx` as either an Integer (flat address into the
  # row-major element sequence) or an `Array<Integer>` (one index
  # per axis). They bypass the broadcasting and view-construction
  # paths used by `[]` / `[]=`, and are the right tool for
  # tight per-cell loops where allocation matters.

  # @overload elem_swap(idx1, idx2)
  #   Exchanges the values (and mask states, if any) at positions
  #   `idx1` and `idx2`. Mutates `self`.
  #   @param idx1 [Integer, Array<Integer>]
  #   @param idx2 [Integer, Array<Integer>]
  #   @return [self]
  def elem_swap(idx1, idx2); end

  # @overload elem_copy(idx1, idx2)
  #   Copies the value (and mask state) at `idx1` into the cell at
  #   `idx2`. The source cell is unchanged. Mutates `self`.
  #   @param idx1 [Integer, Array<Integer>] source position.
  #   @param idx2 [Integer, Array<Integer>] destination position.
  #   @return [self]
  def elem_copy(idx1, idx2); end

  # @overload elem_store(idx, value)
  #   Stores `value` (cast to `self.data_type`) at position `idx`,
  #   clearing the mask state at that cell. Passing `UNDEF` masks
  #   the cell.
  #   @param idx [Integer, Array<Integer>]
  #   @param value [Object]
  #   @return [Object] `value`.
  def elem_store(idx, value); end

  # @overload elem_fetch(idx)
  #   Returns the value at position `idx` (cast back to the
  #   appropriate Ruby type). Returns `UNDEF` if the cell is masked.
  #   Returns `nil` if `self.empty?`.
  #   @param idx [Integer, Array<Integer>]
  #   @return [Object, nil]
  def elem_fetch(idx); end

  # @overload elem_incr(idx)
  #   Increments the value at `idx` by 1 in place. Mutates `self`.
  #   Masked cells are skipped.
  #   @param idx [Integer, Array<Integer>]
  #   @return [self]
  def elem_incr(idx); end

  # @overload elem_decr(idx)
  #   Decrements the value at `idx` by 1 in place. Mutates `self`.
  #   Masked cells are skipped.
  #   @param idx [Integer, Array<Integer>]
  #   @return [self]
  def elem_decr(idx); end

  # @overload elem_min(idx, v)
  #   Updates the cell at `idx` to `min(self[idx], v)`. Mutates `self`.
  #
  #   Masked cells are skipped. NaN follows the `fmin` rule (NaN is
  #   treated as missing: `min(NaN, v) == v`, `min(x, NaN) == x`).
  #   @param idx [Integer, Array<Integer>]
  #   @param v [Numeric]
  #   @return [self]
  #   @raise [CArray::DataTypeError] for non-numeric `data_type`.
  def elem_min(idx, v); end

  # @overload elem_max(idx, v)
  #   Updates the cell at `idx` to `max(self[idx], v)`. Mutates `self`.
  #
  #   Masked cells are skipped. NaN follows the `fmax` rule.
  #   @param idx [Integer, Array<Integer>]
  #   @param v [Numeric]
  #   @return [self]
  #   @raise [CArray::DataTypeError] for non-numeric `data_type`.
  def elem_max(idx, v); end

  # @!endgroup

  # @!group Element access

  # @overload elem_masked?(idx)
  #   Returns `true` if the cell at `idx` is masked.
  #   @param idx [Integer, Array<Integer>]
  #   @return [Boolean]
  def elem_masked?(idx); end

  # @overload elem_mask(idx)
  #   Marks the cell at `idx` as masked. Allocates the mask array if
  #   `self` does not yet have one. Mutates `self`.
  #   @param idx [Integer, Array<Integer>]
  #   @return [self]
  def elem_mask(idx); end

  # @overload elem_unmask(idx)
  #   Clears the mask state at `idx`, leaving the stored data
  #   unchanged. Mutates `self`.
  #   @param idx [Integer, Array<Integer>]
  #   @return [self]
  def elem_unmask(idx); end

  # @!endgroup
end
