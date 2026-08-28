# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for the CA_* cast shorthands, the CArray type-conversion family,
# and the cast-family class methods defined in ext/carray_cast.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Container for the global `CA_*` cast shorthands installed by
# CArray (via `rb_define_global_function`).  Each `CA_<TYPE>(obj)`
# is a top-level function that coerces `obj` (a CArray, Array,
# Numeric, or anything castable) into a CArray of the named element
# type, equivalent to `obj.to_ca.as_type(:<type>)`.
module Kernel
  # @!group CArray cast shorthands

  # Coerces `obj` into a `:boolean` CArray. @return [CArray]
  def CA_BOOLEAN(obj); end
  # Coerces `obj` into an `:int8` CArray. @return [CArray]
  def CA_INT8(obj); end
  # Coerces `obj` into a `:uint8` CArray. @return [CArray]
  def CA_UINT8(obj); end
  # Coerces `obj` into an `:int16` CArray. @return [CArray]
  def CA_INT16(obj); end
  # Coerces `obj` into a `:uint16` CArray. @return [CArray]
  def CA_UINT16(obj); end
  # Coerces `obj` into an `:int32` CArray. @return [CArray]
  def CA_INT32(obj); end
  # Coerces `obj` into a `:uint32` CArray. @return [CArray]
  def CA_UINT32(obj); end
  # Coerces `obj` into an `:int64` CArray. @return [CArray]
  def CA_INT64(obj); end
  # Coerces `obj` into a `:uint64` CArray. @return [CArray]
  def CA_UINT64(obj); end
  # Coerces `obj` into a `:float32` CArray. @return [CArray]
  def CA_FLOAT32(obj); end
  # Coerces `obj` into a `:float64` CArray. @return [CArray]
  def CA_FLOAT64(obj); end
  # Coerces `obj` into a `:cmplx64` CArray. @return [CArray]
  def CA_CMPLX64(obj); end
  # Coerces `obj` into a `:cmplx128` CArray. @return [CArray]
  def CA_CMPLX128(obj); end
  # Coerces `obj` into an `:object` CArray. @return [CArray]
  def CA_OBJECT(obj); end
  # Coerces `obj` into a `CA_SIZE` (platform native size) CArray.
  # @return [CArray]
  def CA_SIZE(obj); end
  # Coerces `obj` into a `:fixlen` CArray. @return [CArray]
  def CA_FIXLEN(obj); end

  # Alias of {#CA_UINT8}. @return [CArray]
  def CA_BYTE(obj); end
  # Alias of {#CA_INT16}. @return [CArray]
  def CA_SHORT(obj); end
  # Alias of {#CA_INT32}. @return [CArray]
  def CA_INT(obj); end
  # Alias of {#CA_FLOAT32}. @return [CArray]
  def CA_FLOAT(obj); end
  # Alias of {#CA_FLOAT64}. @return [CArray]
  def CA_DOUBLE(obj); end
  # Alias of {#CA_CMPLX64}. @return [CArray]
  def CA_COMPLEX(obj); end
  # Alias of {#CA_CMPLX128}. @return [CArray]
  def CA_DCOMPLEX(obj); end

  # @!endgroup
end

class CArray
  # @!group Type casting

  # -- to_type: eager copy conversion -----------------------------------

  # @overload to_type(data_type, bytes: nil)
  #   Returns a new entity holding the elements of `self` converted to
  #   `data_type` (an eager copy that owns its storage). Masked cells are
  #   carried across. When `data_type` is a data_class (a CAStruct
  #   subclass) the result is wrapped in CARecord.
  #
  #   When `self` is an `:object` array and `data_type` is an integer or
  #   float type, each cell is parsed with Ruby `Integer()` / `Float()`
  #   rules and a cell that cannot be parsed becomes UNDEF (masked) rather
  #   than a silent `0.0` or a raise. This is symmetric for float and int:
  #   `nil`, `""`, `"xx"`, and (for int targets) a non-integer string such
  #   as `"1.5"` all map to UNDEF. Explicit `nan` / `inf` / `infinity`
  #   literals (optional sign, case-insensitive, matched as a whole token)
  #   are kept as NaN / ±Infinity.
  #   @param data_type [Symbol, Integer, Class, String] target element type.
  #   @param bytes [Integer, nil] element width in bytes, required for
  #     `:fixlen`.
  #   @return [CArray]
  def to_type(data_type, bytes: nil); end

  # @overload boolean
  #   Returns a `:boolean` copy of `self`. Short-hand of `to_type(:boolean)`.
  #   @return [CArray]
  def boolean; end
  # @overload int8
  #   Returns an `:int8` copy of `self`. Short-hand of `to_type(:int8)`.
  #   @return [CArray]
  def int8; end
  # @overload uint8
  #   Returns a `:uint8` copy of `self`. Short-hand of `to_type(:uint8)`.
  #   @return [CArray]
  def uint8; end
  # @overload int16
  #   Returns an `:int16` copy of `self`. Short-hand of `to_type(:int16)`.
  #   @return [CArray]
  def int16; end
  # @overload uint16
  #   Returns a `:uint16` copy of `self`. Short-hand of `to_type(:uint16)`.
  #   @return [CArray]
  def uint16; end
  # @overload int32
  #   Returns an `:int32` copy of `self`. Short-hand of `to_type(:int32)`.
  #   @return [CArray]
  def int32; end
  # @overload uint32
  #   Returns a `:uint32` copy of `self`. Short-hand of `to_type(:uint32)`.
  #   @return [CArray]
  def uint32; end
  # @overload int64
  #   Returns an `:int64` copy of `self`. Short-hand of `to_type(:int64)`.
  #   @return [CArray]
  def int64; end
  # @overload uint64
  #   Returns a `:uint64` copy of `self`. Short-hand of `to_type(:uint64)`.
  #   @return [CArray]
  def uint64; end
  # @overload float32
  #   Returns a `:float32` copy of `self`. Short-hand of `to_type(:float32)`.
  #   @return [CArray]
  def float32; end
  # @overload float64
  #   Returns a `:float64` copy of `self`. Short-hand of `to_type(:float64)`.
  #   @return [CArray]
  def float64; end
  # @overload cmplx64
  #   Returns a `:cmplx64` copy of `self`. Short-hand of `to_type(:cmplx64)`.
  #   @return [CArray]
  def cmplx64; end
  # @overload cmplx128
  #   Returns a `:cmplx128` copy of `self`. Short-hand of `to_type(:cmplx128)`.
  #   @return [CArray]
  def cmplx128; end
  # @overload object
  #   Returns an `:object` copy of `self`. Short-hand of `to_type(:object)`.
  #   @return [CArray]
  def object; end
  # @overload fixlen(bytes: nil)
  #   Returns a `:fixlen` copy of `self`. Short-hand of
  #   `to_type(:fixlen, bytes:)`.
  #   @param bytes [Integer, nil] fixed element width in bytes.
  #   @return [CArray]
  def fixlen(bytes: nil); end

  # @overload byte
  #   Alias of {#uint8}. @return [CArray]
  def byte; end
  # @overload short
  #   Alias of {#int16}. @return [CArray]
  def short; end
  # @overload int
  #   Alias of {#int32}. @return [CArray]
  def int; end
  # @overload float
  #   Alias of {#float32}. @return [CArray]
  def float; end
  # @overload double
  #   Alias of {#float64}. @return [CArray]
  def double; end
  # @overload complex
  #   Alias of {#cmplx64}. @return [CArray]
  def complex; end
  # @overload dcomplex
  #   Alias of {#cmplx128}. @return [CArray]
  def dcomplex; end

  # -- as_type: reinterpreting view (no copy) ---------------------------

  # @overload as_type(data_type, bytes: nil)
  #   Returns a {CAFake} view of `self` reinterpreted as `data_type`
  #   (with `bytes:` for `:fixlen`). Reads and writes cast on the fly
  #   through the shared parent storage; no copy is made. For an eager
  #   copy use `arr.as_type(...).to_ca` or {#to_type}.
  #
  #   Note: for an `:object` source the on-the-fly cast to a numeric type
  #   uses the lenient path and does NOT mask parse failures — a
  #   non-numeric string reads as `0.0` (float) and raises for an integer
  #   target. Use {#to_type} instead for parse-with-mask (an unparseable
  #   cell becomes UNDEF). The `CA_<TYPE>(obj)` construction shorthands
  #   take this same non-masking path.
  #   A Face refuses: reinterpreting its storage would hand back the
  #   bytes its surface exists to hide (the serial instead of the time, the
  #   descriptor instead of the string), and no view decodes a surface. Take
  #   the values with {#to_type}, or the storage with `face.parent.as_type`.
  #   A Numeric Face, whose surface *is* its storage, adapts as usual.
  #   @param data_type [Symbol, Integer, Class, String] target element type.
  #   @param bytes [Integer, nil] element width in bytes, required for
  #     `:fixlen`.
  #   @return [CAFake]
  #   @raise [TypeError] when `self` is a Face and the request would read its
  #     storage under another type.
  def as_type(data_type, bytes: nil); end

  # @overload as_boolean
  #   Returns a {CAFake} `:boolean` view of `self`. Short-hand of
  #   `as_type(:boolean)`.
  #   @return [CAFake]
  def as_boolean; end
  # @overload as_int8
  #   Returns a {CAFake} `:int8` view of `self`. Short-hand of `as_type(:int8)`.
  #   @return [CAFake]
  def as_int8; end
  # @overload as_uint8
  #   Returns a {CAFake} `:uint8` view of `self`. Short-hand of `as_type(:uint8)`.
  #   @return [CAFake]
  def as_uint8; end
  # @overload as_int16
  #   Returns a {CAFake} `:int16` view of `self`. Short-hand of `as_type(:int16)`.
  #   @return [CAFake]
  def as_int16; end
  # @overload as_uint16
  #   Returns a {CAFake} `:uint16` view of `self`. Short-hand of `as_type(:uint16)`.
  #   @return [CAFake]
  def as_uint16; end
  # @overload as_int32
  #   Returns a {CAFake} `:int32` view of `self`. Short-hand of `as_type(:int32)`.
  #   @return [CAFake]
  def as_int32; end
  # @overload as_uint32
  #   Returns a {CAFake} `:uint32` view of `self`. Short-hand of `as_type(:uint32)`.
  #   @return [CAFake]
  def as_uint32; end
  # @overload as_int64
  #   Returns a {CAFake} `:int64` view of `self`. Short-hand of `as_type(:int64)`.
  #   @return [CAFake]
  def as_int64; end
  # @overload as_uint64
  #   Returns a {CAFake} `:uint64` view of `self`. Short-hand of `as_type(:uint64)`.
  #   @return [CAFake]
  def as_uint64; end
  # @overload as_float32
  #   Returns a {CAFake} `:float32` view of `self`. Short-hand of
  #   `as_type(:float32)`.
  #   @return [CAFake]
  def as_float32; end
  # @overload as_float64
  #   Returns a {CAFake} `:float64` view of `self`. Short-hand of
  #   `as_type(:float64)`.
  #   @return [CAFake]
  def as_float64; end
  # @overload as_float128
  #   Returns a {CAFake} `:float128` view of `self`. Short-hand of
  #   `as_type(:float128)`.
  #   @return [CAFake]
  def as_float128; end
  # @overload as_cmplx64
  #   Returns a {CAFake} `:cmplx64` view of `self`. Short-hand of
  #   `as_type(:cmplx64)`.
  #   @return [CAFake]
  def as_cmplx64; end
  # @overload as_cmplx128
  #   Returns a {CAFake} `:cmplx128` view of `self`. Short-hand of
  #   `as_type(:cmplx128)`.
  #   @return [CAFake]
  def as_cmplx128; end
  # @overload as_cmplx256
  #   Returns a {CAFake} `:cmplx256` view of `self`. Short-hand of
  #   `as_type(:cmplx256)`.
  #   @return [CAFake]
  def as_cmplx256; end
  # @overload as_object
  #   Returns a {CAFake} `:object` view of `self`. Short-hand of
  #   `as_type(:object)`.
  #   @return [CAFake]
  def as_object; end
  # @overload as_fixlen(bytes: nil)
  #   Returns a {CAFake} `:fixlen` view of `self`. Short-hand of
  #   `as_type(:fixlen, bytes:)`.
  #   @param bytes [Integer, nil] fixed element width in bytes.
  #   @return [CAFake]
  def as_fixlen(bytes: nil); end

  # @overload as_byte
  #   Alias of {#as_uint8}. @return [CAFake]
  def as_byte; end
  # @overload as_short
  #   Alias of {#as_int16}. @return [CAFake]
  def as_short; end
  # @overload as_int
  #   Alias of {#as_int32}. @return [CAFake]
  def as_int; end
  # @overload as_float
  #   Alias of {#as_float32}. @return [CAFake]
  def as_float; end
  # @overload as_double
  #   Alias of {#as_float64}. @return [CAFake]
  def as_double; end
  # @overload as_complex
  #   Alias of {#as_cmplx64}. @return [CAFake]
  def as_complex; end
  # @overload as_dcomplex
  #   Alias of {#as_cmplx128}. @return [CAFake]
  def as_dcomplex; end

  # -- clip-then-cast ---------------------------------------------------

  # @!method clip_int8
  #   Returns an `:int8` copy of `self` with values clamped to the
  #   `:int8` range (-128..127) before casting. @return [CArray]
  # @!method clip_uint8
  #   Returns a `:uint8` copy clamped to 0..255. @return [CArray]
  # @!method clip_int16
  #   Returns an `:int16` copy clamped to -32768..32767.
  #   @return [CArray]
  # @!method clip_uint16
  #   Returns a `:uint16` copy clamped to 0..65535. @return [CArray]
  # @!method clip_int32
  #   Returns an `:int32` copy clamped to the `:int32` range.
  #   @return [CArray]
  # @!method clip_uint32
  #   Returns a `:uint32` copy clamped to 0..4294967295.
  #   @return [CArray]
  # @!method clip_int64
  #   Returns an `:int64` copy clamped to the `:int64` range.
  #   @return [CArray]
  # @!method clip_uint64
  #   Returns a `:uint64` copy clamped to the `:uint64` range.
  #   @return [CArray]

  # -- coercion ---------------------------------------------------------

  # @overload cast_with(other)
  #   Returns a two-element `[self, other]` array with both operands
  #   coerced to a common representation under the CArray casting policy.
  #   Non-CArray operands are promoted to a CArray (MemoryView producers
  #   are wrapped, Ruby scalars become a CScalar), then the narrower side
  #   is wrapped read-only in the common data_type. This is the coercion
  #   primitive the binary operators use.
  #   @param other [CArray, Object] the second operand.
  #   @return [Array(CArray, CArray)]
  #   @raise [RuntimeError] when the two data_types have no common type.
  def cast_with(other); end

  # `coerce` is documented with its definition in ext/carray_operator.c;
  # the bare signature here only attaches it to the "Type casting" group.
  def coerce(other); end # @!visibility public

  # -- class methods ----------------------------------------------------

  # @overload wrap_writable(other, data_type = nil)
  #   Returns `other` as a CArray you intend to **write into**, reinterpreted
  #   as `data_type` when given.
  #
  #   The name is a statement of intent, not a property of the result: you are
  #   declaring that writes are coming, so only sources that can actually take
  #   a write are accepted — a writable CArray, `nil` (a zero-filled CScalar),
  #   an object whose `#to_ca` honours `writable: true`, or a writable
  #   MemoryView producer (wrapped zero-copy). Anything that would have to be
  #   *copied* to become a CArray is refused up front, because a copy would
  #   swallow the writes silently. That is the whole difference from
  #   {.wrap_readonly}, which is free to copy and so accepts far more.
  #
  #   For a foreign object the refusal is the object's own to make: this calls
  #   `other.to_ca(writable: true)`, which is the caller's half of the
  #   {CArray#to_ca} contract — "give me a CArray *whose writes reach you*" —
  #   and a `to_ca` that can only produce a copy raises rather than answering.
  #   An object whose `to_ca` predates the keyword raises `ArgumentError`,
  #   which is the honest report that it does not implement writable intake.
  #
  #   When `data_type` differs from the source element type the result is a
  #   type-adapting view over the same storage, and a write reverse-casts
  #   through to the source. A Face is refused for that same reason the
  #   other way round: the writes would land on the storage its surface
  #   hides. Wrap `face.parent` when that is what you mean.
  #   @param other [CArray, nil, Object] source to wrap.
  #   @param data_type [Symbol, Integer, Class, nil] target element type;
  #     `nil` keeps the source type (or `:object` when `other` is `nil`).
  #   @return [CArray]
  #   @raise [RuntimeError] when `other` is read-only, its MemoryView is
  #     read-only, its `to_ca` refuses `writable: true`, or it cannot be
  #     wrapped as a CArray.
  #   @raise [TypeError] when `other#to_ca` returns something that is not a
  #     CArray.
  #   @raise [ArgumentError] when `other#to_ca` does not accept `writable:`.
  #   @raise [TypeError] when `other` is a Face and `data_type` differs from
  #     its surface type.
  def self.wrap_writable(other, data_type = nil); end

  # @overload wrap_readonly(other, data_type = nil)
  #   Returns `other` as a CArray you intend to **only read**, reinterpreted
  #   as `data_type` when given.
  #
  #   The name is a statement of intent, not a property of the result: you are
  #   declaring that nothing will be written back, which frees this call to
  #   convert as widely as it can — a conversion that copies is fine when
  #   nobody writes to it. So on top of everything {.wrap_writable} takes
  #   (a CArray, `nil`, an object responding to `#to_ca`, a MemoryView
  #   producer) this also accepts an Array (via `to_ca`) and a Numeric /
  #   String / arbitrary object, which become a one-element CScalar. It calls
  #   `to_ca` with no arguments, so a copy is welcome here.
  #
  #   It does **not** make the source read-only, and does not protect it: for
  #   a CArray whose element type already matches you get back the very same
  #   object, and a type-adapting view writes through to its source. Keeping
  #   the read-only promise is the caller's part of the bargain.
  #
  #   Two conversions are worth knowing before you rely on them: with a
  #   numeric `data_type` a String is reinterpreted as **raw bytes** (a copy),
  #   not parsed, so `"abcd"` with `:uint8` gives four elements; and with
  #   `data_type` omitted, anything that is not already CArray-shaped lands on
  #   `:object` rather than a guessed numeric type, so pass `data_type`
  #   explicitly when the value is headed for a numeric kernel.
  #   A Face answers with the same conversion {#to_type} performs, since
  #   nothing here promises a view: its surface values for `:object`, and its
  #   own `#to_numeric` for a numeric type. Reading its storage instead is
  #   `face.parent`.
  #   @param other [CArray, Numeric, String, Array, nil, Object] source to
  #     wrap.
  #   @param data_type [Symbol, Integer, Class, nil] target element type;
  #     `nil` keeps the source type for a CArray-shaped source, and is
  #     `:object` otherwise.
  #   @return [CArray]
  #   @raise [TypeError] when `other` is a Face asked for a numeric type and
  #     it declares no `#to_numeric`.
  def self.wrap_readonly(other, data_type = nil); end

  # @overload cast(value)
  #   Returns `value` as a CArray. A CArray is returned unchanged; a Ruby
  #   value is coerced: Integer to an `:int64` CScalar, Float to
  #   `:float64`, true/false to `:boolean`, Complex to `:cmplx128`, Array
  #   and Range via `to_ca`, and anything else to an `:object` CScalar.
  #   @param value [Object] the value to coerce.
  #   @return [CArray]
  def self.cast(value); end

  # @overload result_type(*args)
  #   Returns the common data_type Symbol that all of the given operands
  #   can be promoted to under the CArray casting policy.
  #
  #   Each argument is classified as either a *data_type representation*
  #   or a *value*:
  #
  #   - CArray instance -> its `data_type`
  #   - Symbol / String / Class -> data_type representation (name lookup)
  #   - Integer / Float / Complex / true / false / nil / Object -> *value*,
  #     data_type inferred (3 -> `:int64`, 3.14 -> `:float64`,
  #     1+2i -> `:cmplx128`, ...)
  #
  #   Values and data_type representations promote uniformly. Integer args
  #   are interpreted as *values*, not as data_type codes:
  #   `result_type(8)` returns `:int64` because the value 8 is an Integer,
  #   not because a data_type code equals 8. Use `result_type(:int64)` or
  #   `result_type(CA_INT64)` to be explicit about data_type intent.
  #   @param args [Array<CArray, Symbol, String, Class, Object>] operands.
  #   @return [Symbol]
  #   @raise [ArgumentError] when called with no arguments.
  #   @raise [RuntimeError] when two inputs are mutually incompatible
  #     (e.g. `:object` with `:fixlen`).
  #   @example
  #     CArray.result_type(:int32, :float32)  #=> :float32
  #     CArray.result_type(3, 3.14)           #=> :float64
  #     CArray.result_type(true, 3)           #=> :int64
  def self.result_type(*args); end

  # @overload promote_list(list, data_type: nil)
  #   Returns a copy of `list` in which every element is in a
  #   representation that can be uniformly handled (same Face class, or
  #   same primitive data_type). The result is suitable as direct input
  #   to multi-parent constructors such as {CArray.stack}.
  #
  #   With `data_type: nil` (auto-detect): a list of same-class Face
  #   elements passes through (CAStack lifts it), unless the class is not
  #   portable (CAConstString) or the elements disagree on state
  #   (CATime with different units); a list of primitives is
  #   promoted via {.result_type} + {.wrap_readonly}; a mix of Face and
  #   non-Face, or heterogeneous Face classes, is rejected.
  #
  #   With an explicit primitive `data_type`: all-primitive elements are
  #   wrapped read-only to the requested type; any Face element is
  #   rejected (a Face cannot be coerced to a primitive without losing
  #   identity). A Class-shaped `data_type` is rejected.
  #   @param list [Array<CArray>] elements to reconcile.
  #   @param data_type [Symbol, nil] target element type, or `nil` to
  #     auto-detect.
  #   @return [Array<CArray>]
  #   @raise [ArgumentError] on an empty list or any of the reject cases.
  def self.promote_list(list, data_type: nil); end

  # @!endgroup
end
