# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for singleton methods defined in ext/carray_class.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  class << self
    # @!group Platform inquiries

    # @overload endian
    #   Returns the host byte order as an Integer: `0`
    #   (`CA_LITTLE_ENDIAN`) or `1` (`CA_BIG_ENDIAN`). Prefer
    #   {.big_endian?} / {.little_endian?} for predicate use.
    #   @return [Integer]
    def endian; end

    # @overload big_endian?
    #   Returns `true` if the host byte order is big-endian.
    #   @return [Boolean]
    def big_endian?; end

    # @overload little_endian?
    #   Returns `true` if the host byte order is little-endian.
    #   @return [Boolean]
    def little_endian?; end

    # @!endgroup

    # @!group Data-type inquiries

    # @overload sizeof(data_type)
    #   Returns the byte size of one element of `data_type`. Returns
    #   `0` for `:fixlen` (the byte size of a fixlen array is
    #   per-instance and read via `CArray#bytes`).
    #   @param data_type [Symbol, Integer, Class, String] data type
    #     in any accepted form.
    #   @return [Integer]
    #   @example
    #     CArray.sizeof(:int32)    # => 4
    #     CArray.sizeof(:float64)  # => 8
    #     CArray.sizeof(:fixlen)   # => 0
    def sizeof(data_type); end

    # @overload data_type_name(data_type)
    #   Returns the String name of `data_type` (e.g. `"int32"`,
    #   `"float64"`, `"fixlen"`).
    #   @param data_type [Symbol, Integer, Class, String]
    #   @return [String]
    def data_type_name(data_type); end

    # @overload data_type_code(data_type)
    #   Returns the internal `int8_t` numeric code of `data_type`
    #   (e.g. `8` for `:int64`, `11` for `:float64`). Inverse of
    #   {.data_type_name}.
    #
    #   Primarily used by Ruby-side code that needs to compute kernel
    #   op ids (e.g. `CAMonOp::CAST_BASE + code` in
    #   `lib/carray/lazy.rb`). End users normally do not need this —
    #   compare Symbols or use the `CA_*` constants directly.
    #   @param data_type [Symbol, Integer, Class, String]
    #   @return [Integer]
    def data_type_code(data_type); end

    # @!endgroup
  end
end
