# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_conversion.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Copy and conversion

  # @overload to_a
  #   Returns a newly allocated Ruby `Array` containing the element
  #   values of `self`. For `ndim >= 2`, the result is nested:
  #   `shape == [2, 3]` ⇒ a 2-element `Array` of 3-element `Array`s.
  #
  #   Masked cells materialise as `CArray::UNDEF`; the mask state
  #   itself is not preserved on the result.
  #   @return [Array]
  #   @example
  #     CArray.float64(2, 3) { |i, j| i + j }.to_a
  #     # => [[0.0, 1.0, 2.0], [1.0, 2.0, 3.0]]
  def to_a; end

  # @overload convert(data_type = nil, bytes: nil) { |elem| ... }
  #   Returns a new CArray of the same shape as `self`, each element
  #   set to the block's return value applied to the corresponding
  #   element of `self`. The output array is built via {#template},
  #   so `data_type` (and `bytes:` for `:fixlen`) selects the result
  #   type; omit them to inherit `self.data_type`.
  #
  #   Masked cells skip the block; if the block returns
  #   `CArray::UNDEF`, the corresponding output cell is masked.
  #   @param data_type [Symbol, Integer, Class, String, nil]
  #   @param bytes [Integer, nil] element byte size for `:fixlen`.
  #   @yieldparam elem [Object] one element of `self`.
  #   @yieldreturn [Object] value to store in the result.
  #   @return [CArray]
  def convert(data_type = nil, bytes: nil, &block); end

  # @!endgroup

  # @!group Copy and conversion

  # @overload dump_binary
  #   Returns a new binary String containing the raw element bytes of
  #   `self` in row-major order.
  #   @return [String]
  #   @raise [CArray::DataTypeError] if `self.data_type` is
  #     `:object`.
  # @overload dump_binary(io)
  #   Writes the raw element bytes of `self` to `io` and returns
  #   `io`. `io` may be a `String` (resized and overwritten), an
  #   `IO`, or any object responding to `write`.
  #   @param io [String, IO, #write]
  #   @return [String, IO, Object] the `io` argument.
  #   @raise [CArray::DataTypeError] if `self.data_type` is
  #     `:object`.
  def dump_binary(io = nil); end

  # @overload to_s
  #   Equivalent to `dump_binary` with no arguments. Returns the raw
  #   element bytes of `self` as a binary String.
  #   @return [String]
  def to_s; end

  # @overload load_binary(io)
  #   Reads `ca_length(self)` bytes from `io` and overwrites the
  #   element data of `self` in row-major order. `io` may be a
  #   `String` of the exact size, or any object responding to
  #   `read(n, buf = nil)`.
  #   @param io [String, IO, #read]
  #   @return [self]
  #   @raise [RuntimeError] on short read or size mismatch.
  #   @raise [CArray::DataTypeError] if `self.data_type` is
  #     `:object`.
  def load_binary(io); end

  # @!endgroup
end
