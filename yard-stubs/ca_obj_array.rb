# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for constructor methods defined in ext/ca_obj_array.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Construction

  # @overload initialize(data_type, shape)
  #   Allocates a CArray of the given `data_type` and `shape`, with
  #   storage left uninitialized (caller is expected to fill it).
  #   @param data_type [Symbol, Integer, Class, String] element type.
  #   @param shape [Array<Integer>] one extent per axis.
  #   @return [self]
  # @overload initialize(data_type, shape, bytes:)
  #   For `data_type == :fixlen`, sets the per-element byte size.
  #   Ignored for numeric types.
  #   @param data_type [Symbol]
  #   @param shape [Array<Integer>]
  #   @param bytes [Integer]
  #   @return [self]
  # @overload initialize(data_type, shape) { value }
  #   With a 0-arity block, calls the block once and broadcasts its
  #   return value into every cell of the new array (scalar-fill fast
  #   path). This is the dominant
  #   `CArray.<type>(n) { value }` idiom.
  #   @yieldreturn [Object] value to broadcast.
  #   @return [self]
  # @overload initialize(data_type, shape) { |*idx| ... }
  #   With an n-arity block, calls the block once per cell with the
  #   multi-dimensional index unpacked (`|i|` for 1-D, `|i, j|` for
  #   2-D, etc.). The block's return value is stored at that cell.
  #   @yieldparam idx [Array<Integer>] per-axis indices.
  #   @yieldreturn [Object]
  #   @return [self]
  #
  #   3.0 breaking: `CArray.new(MyStruct, ...)` no longer accepts a
  #   user class as `data_type`. Use `CARecord.new(MyStruct, *shape)`
  #   or define `class MyArr < CARecord; data_class MyStruct; end`.
  def initialize(*); end

  # @overload initialize_copy(other)
  #   Implements `dup` / `clone` semantics: copies `other`'s
  #   `data_type`, shape, mask, and element data into `self`. Result
  #   is an independent entity.
  #
  #   Note that for views, `dup`/`clone` produce a new view sharing
  #   the parent (Ruby shallow-copy semantics); use {#copy} when an
  #   independent owned array is required.
  #   @param other [CArray]
  #   @return [self]
  #   @api private
  def initialize_copy(other); end

  # @!endgroup

  class << self
    # @!group Construction (typed shorthands)
    #
    # `CArray.<type>` (no args) returns the typed class
    # (`CArray::Float64`, `CArray::Int32`, ...). `CArray.<type>(*shape)`
    # is a shorthand for `CArray.new(:<type>, shape)`. The shorthands
    # accept the same optional block as `initialize`.

    # @overload fixlen
    #   Returns the typed class `CArray::Fixlen`.
    #   @return [Class]
    # @overload fixlen(*shape, bytes:) { ... }
    #   Equivalent to `CArray.new(:fixlen, shape, bytes: bytes) { ... }`.
    #   The `bytes:` keyword is required for `:fixlen`.
    #   @param shape [Array<Integer>]
    #   @param bytes [Integer]
    #   @return [CArray]
    def fixlen(*shape, bytes: nil); end

    # @overload boolean
    #   Returns the typed class `CArray::Boolean`.
    #   @return [Class]
    # @overload boolean(*shape) { ... }
    #   Equivalent to `CArray.new(:boolean, shape) { ... }`.
    #   @param shape [Array<Integer>]
    #   @return [CArray]
    def boolean(*shape); end

    # @overload int8
    #   Returns the typed class `CArray::Int8`.
    #   @return [Class]
    # @overload int8(*shape) { ... }
    #   Equivalent to `CArray.new(:int8, shape) { ... }`.
    #   @return [CArray]
    def int8(*shape); end

    # @overload uint8
    #   Returns the typed class `CArray::UInt8`.
    #   @return [Class]
    # @overload uint8(*shape) { ... }
    #   Equivalent to `CArray.new(:uint8, shape) { ... }`.
    #   @return [CArray]
    def uint8(*shape); end

    # @overload int16
    #   Returns the typed class `CArray::Int16`.
    #   @return [Class]
    # @overload int16(*shape) { ... }
    #   Equivalent to `CArray.new(:int16, shape) { ... }`.
    #   @return [CArray]
    def int16(*shape); end

    # @overload uint16
    #   Returns the typed class `CArray::UInt16`.
    #   @return [Class]
    # @overload uint16(*shape) { ... }
    #   Equivalent to `CArray.new(:uint16, shape) { ... }`.
    #   @return [CArray]
    def uint16(*shape); end

    # @overload int32
    #   Returns the typed class `CArray::Int32`.
    #   @return [Class]
    # @overload int32(*shape) { ... }
    #   Equivalent to `CArray.new(:int32, shape) { ... }`.
    #   @return [CArray]
    def int32(*shape); end

    # @overload uint32
    #   Returns the typed class `CArray::UInt32`.
    #   @return [Class]
    # @overload uint32(*shape) { ... }
    #   Equivalent to `CArray.new(:uint32, shape) { ... }`.
    #   @return [CArray]
    def uint32(*shape); end

    # @overload int64
    #   Returns the typed class `CArray::Int64`.
    #   @return [Class]
    # @overload int64(*shape) { ... }
    #   Equivalent to `CArray.new(:int64, shape) { ... }`.
    #   @return [CArray]
    def int64(*shape); end

    # @overload uint64
    #   Returns the typed class `CArray::UInt64`.
    #   @return [Class]
    # @overload uint64(*shape) { ... }
    #   Equivalent to `CArray.new(:uint64, shape) { ... }`.
    #   @return [CArray]
    def uint64(*shape); end

    # @overload float32
    #   Returns the typed class `CArray::Float32`.
    #   @return [Class]
    # @overload float32(*shape) { ... }
    #   Equivalent to `CArray.new(:float32, shape) { ... }`.
    #   @return [CArray]
    def float32(*shape); end

    # @overload float64
    #   Returns the typed class `CArray::Float64`.
    #   @return [Class]
    # @overload float64(*shape) { ... }
    #   Equivalent to `CArray.new(:float64, shape) { ... }`.
    #   @return [CArray]
    def float64(*shape); end

    # @overload cmplx64
    #   Returns the typed class `CArray::Cmplx64`.
    #   @return [Class]
    # @overload cmplx64(*shape) { ... }
    #   Equivalent to `CArray.new(:cmplx64, shape) { ... }`.
    #   @return [CArray]
    def cmplx64(*shape); end

    # @overload cmplx128
    #   Returns the typed class `CArray::Cmplx128`.
    #   @return [Class]
    # @overload cmplx128(*shape) { ... }
    #   Equivalent to `CArray.new(:cmplx128, shape) { ... }`.
    #   @return [CArray]
    def cmplx128(*shape); end

    # @overload object
    #   Returns the typed class `CArray::Object`.
    #   @return [Class]
    # @overload object(*shape) { ... }
    #   Equivalent to `CArray.new(:object, shape) { ... }`.
    #   @return [CArray]
    def object(*shape); end

    # @!endgroup

    # @!group Construction (legacy-name aliases)

    # @overload byte(*shape)
    #   Alias of {.uint8}.
    def byte(*shape); end

    # @overload short(*shape)
    #   Alias of {.int16}.
    def short(*shape); end

    # @overload int(*shape)
    #   Alias of {.int32}.
    def int(*shape); end

    # @overload float(*shape)
    #   Alias of {.float32}.
    def float(*shape); end

    # @overload double(*shape)
    #   Alias of {.float64}.
    def double(*shape); end

    # @overload complex(*shape)
    #   Alias of {.cmplx64}.
    def complex(*shape); end

    # @overload dcomplex(*shape)
    #   Alias of {.cmplx128}.
    def dcomplex(*shape); end

    # @!endgroup

    # @!group External memory wrapping

    # @overload wrap(data_type, shape) { target }
    #   Wraps an external memory block as a CAWrap. The block must
    #   return a `target` object that defines `wrap_as_carray(obj)`,
    #   which receives the freshly allocated CAWrap and is
    #   responsible for setting its `ptr` field.
    #
    #   Use this when bridging to a memory source that does not
    #   expose the MemoryView protocol (otherwise prefer
    #   {.wrap_memory_view} / {.from_memory_view}).
    #   @param data_type [Symbol]
    #   @param shape [Array<Integer>]
    #   @yieldreturn [#wrap_as_carray] external buffer holder.
    #   @return [CAWrap]
    def wrap(data_type, shape); end

    # @!endgroup
  end
end

class CScalar
  # @!group Construction

  # @overload initialize(data_type)
  #   Allocates a CScalar (0-D CArray) of the given `data_type`.
  #   @param data_type [Symbol, Integer, Class, String]
  #   @return [self]
  # @overload initialize(data_type, bytes:)
  #   For `data_type == :fixlen`, sets the per-element byte size.
  #   @param data_type [Symbol]
  #   @param bytes [Integer]
  #   @return [self]
  # @overload initialize(data_type) { |scalar| ... }
  #   Yields the freshly allocated scalar; the block's return value
  #   is stored at the cell unless it is `scalar` itself.
  #   @yieldparam scalar [CScalar]
  #   @yieldreturn [Object]
  #   @return [self]
  def initialize(*); end

  # @overload initialize_copy(other)
  #   Copies `other`'s `data_type` and stored value into `self`.
  #   @param other [CScalar]
  #   @return [self]
  #   @api private
  def initialize_copy(other); end

  # @!endgroup

  class << self
    # @!group Construction (typed shorthands)

    # @overload fixlen(bytes:) { ... }
    #   Equivalent to `CScalar.new(:fixlen, bytes: bytes) { ... }`.
    #   @param bytes [Integer]
    #   @return [CScalar]
    def fixlen(bytes:); end

    # @overload boolean { ... }
    #   Equivalent to `CScalar.new(:boolean) { ... }`.
    #   @return [CScalar]
    def boolean; end

    # @overload int8 { ... }
    #   Equivalent to `CScalar.new(:int8) { ... }`.
    #   @return [CScalar]
    def int8; end

    # @overload uint8 { ... }
    #   Equivalent to `CScalar.new(:uint8) { ... }`.
    #   @return [CScalar]
    def uint8; end

    # @overload int16 { ... }
    #   Equivalent to `CScalar.new(:int16) { ... }`.
    #   @return [CScalar]
    def int16; end

    # @overload uint16 { ... }
    #   Equivalent to `CScalar.new(:uint16) { ... }`.
    #   @return [CScalar]
    def uint16; end

    # @overload int32 { ... }
    #   Equivalent to `CScalar.new(:int32) { ... }`.
    #   @return [CScalar]
    def int32; end

    # @overload uint32 { ... }
    #   Equivalent to `CScalar.new(:uint32) { ... }`.
    #   @return [CScalar]
    def uint32; end

    # @overload int64 { ... }
    #   Equivalent to `CScalar.new(:int64) { ... }`.
    #   @return [CScalar]
    def int64; end

    # @overload uint64 { ... }
    #   Equivalent to `CScalar.new(:uint64) { ... }`.
    #   @return [CScalar]
    def uint64; end

    # @overload float32 { ... }
    #   Equivalent to `CScalar.new(:float32) { ... }`.
    #   @return [CScalar]
    def float32; end

    # @overload float64 { ... }
    #   Equivalent to `CScalar.new(:float64) { ... }`.
    #   @return [CScalar]
    def float64; end

    # @overload cmplx64 { ... }
    #   Equivalent to `CScalar.new(:cmplx64) { ... }`.
    #   @return [CScalar]
    def cmplx64; end

    # @overload cmplx128 { ... }
    #   Equivalent to `CScalar.new(:cmplx128) { ... }`.
    #   @return [CScalar]
    def cmplx128; end

    # @overload object { ... }
    #   Equivalent to `CScalar.new(:object) { ... }`.
    #   @return [CScalar]
    def object; end

    # @!endgroup

    # @!group Construction (legacy-name aliases)

    # @overload byte
    #   Alias of {.uint8}.
    def byte; end

    # @overload short
    #   Alias of {.int16}.
    def short; end

    # @overload int
    #   Alias of {.int32}.
    def int; end

    # @overload float
    #   Alias of {.float32}.
    def float; end

    # @overload double
    #   Alias of {.float64}.
    def double; end

    # @overload complex
    #   Alias of {.cmplx64}.
    def complex; end

    # @overload dcomplex
    #   Alias of {.cmplx128}.
    def dcomplex; end

    # @!endgroup
  end
end
