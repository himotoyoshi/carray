# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_test.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Index and address conversion

  # @overload valid_index?(*idx)
  #   Returns `true` if the given index tuple is in range for `self`.
  #   The number of indices must equal `ndim`.
  #   @param idx [Array<Integer>] one index per axis.
  #   @return [Boolean]
  #   @raise [ArgumentError] if the number of indices does not match
  #     `ndim`.
  def valid_index?(*idx); end

  # @overload valid_addr?(addr)
  #   Returns `true` if `addr` is in range `0...elements` for `self`.
  #   @param addr [Integer] flat address into the contiguous element
  #     sequence.
  #   @return [Boolean]
  def valid_addr?(addr); end

  # @overload same_shape?(other)
  #   Returns `true` if `other` has the same shape as `self`.
  #   @param other [CArray]
  #   @return [Boolean]
  def same_shape?(other); end

  # @!endgroup

  # @!group Equality and hashing

  # @overload ==(other)
  #   Returns `true` if `other` is a CArray with the same shape,
  #   `data_class`, `data_type`, mask state, and elementwise values as
  #   `self`. NaN values compare unequal (IEEE semantics), so two
  #   arrays with NaN at the same position are not `==`.
  #   @param other [Object]
  #   @return [Boolean]
  def ==(other); end

  # @overload eql?(other)
  #   Returns `true` under Hash-invariant semantics: `data_class`,
  #   `data_type`, shape, and mask state must all match, and elements
  #   are compared bitwise (for numeric types) or via `Object#eql?`
  #   (for `:object` arrays). Unlike `==`, `NaN.eql?(NaN)` holds, so
  #   two mask-free arrays with NaN at the same positions are `eql?`.
  #
  #   Guarantees `a.eql?(b)` ⇒ `a.hash == b.hash`.
  #   @param other [Object]
  #   @return [Boolean]
  def eql?(other); end

  # @overload hash
  #   Returns the Hash key value for `self`. Mixes `data_type`,
  #   `ndim`, `bytes`, `elements`, shape, scalar-ness, and mask
  #   presence; for unmasked arrays, samples the leading 64 bytes of
  #   data. Masked arrays skip the data sample.
  #   @return [Integer]
  def hash; end

  # @!endgroup

  # @!group Equality and hashing

  # @overload freeze
  #   Freezes `self` and marks it read-only. Subsequent mutations
  #   raise `FrozenError`.
  #   @return [self]
  def freeze; end

  # @overload set_read_only_flag
  #   Marks `self` read-only (sets `CA_FLAG_READ_ONLY`) without
  #   freezing the Ruby object, so subsequent mutations raise
  #   `RuntimeError` while `frozen?` stays false and views / Faces
  #   derived from `self` can still memoise. One-way: there is no
  #   method to clear the flag. Use `#copy` for a writable copy (a
  #   copy does not inherit the flag). Contrast `#freeze`, which also
  #   freezes the Ruby object.
  #   @return [self]
  def set_read_only_flag; end

  # @!endgroup
end
