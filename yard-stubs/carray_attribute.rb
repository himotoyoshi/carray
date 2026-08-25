# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_attribute.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Attributes

  # @overload obj_type
  #   Returns the object-type integer of `self` (e.g. `CA_OBJ_ARRAY`,
  #   `CA_OBJ_BLOCK`).
  #
  #   Rarely needed in user code; the same information is available
  #   from `self.class`.
  #   @return [Integer]
  def obj_type; end

  # @!group Type inquiry

  # @overload data_type
  #   Returns the data type of each element as a Symbol (e.g. `:int32`,
  #   `:float64`).
  #   @return [Symbol]
  def data_type; end

  # @overload data_type_name
  #   Returns the String name of `data_type` (e.g. `"int32"`,
  #   `"fixlen"`).
  #   @return [String]
  def data_type_name; end

  # @!group Attributes

  # @overload ndim
  #   Returns the number of dimensions of `self`.
  #   @return [Integer]
  def ndim; end

  # @overload rank
  #   @deprecated Use {#ndim}.
  #   @return [Integer]
  def rank; end

  # @overload bytes
  #   Returns the byte size of one element. Equals
  #   `CArray.sizeof(data_type)` for numeric types; for fixed-length
  #   types this method is the only way to obtain the size.
  #   @return [Integer]
  def bytes; end

  # @overload flags
  #   Returns the raw internal flag bitset (`ca->flags`) as an Integer.
  #   The bits record structural facts about the array (scalar, Face,
  #   view, read-only, …). This is a low-level provenance value with no
  #   stable public meaning; it is exposed mainly so the `_CARRAY3`
  #   serializer can snapshot it into a saved file's header.
  #   @return [Integer]
  def flags; end

  # @overload elements
  #   Returns the total number of elements (product of `shape`).
  #   @return [Integer]
  def elements; end

  # @overload size
  #   Alias of {#elements}.
  #   @return [Integer]
  def size; end

  # @overload length
  #   @deprecated Use {#elements} or {#size}.
  #   @return [Integer]
  def length; end

  # @overload shape
  #   Returns a freshly allocated Array containing the dimensional
  #   shape of `self` (e.g. `[2, 3]` for a 2×3 array).
  #
  #   This is the recommended accessor. {#dim} is a legacy alias.
  #   @return [Array<Integer>]
  #   @example
  #     CArray.float64(2, 3).shape  # => [2, 3]
  def shape; end

  # @overload dim
  #   @deprecated Use {#shape}.
  #   @return [Array<Integer>]
  def dim; end

  # @overload dim0
  #   Returns `shape[0]`.
  #   @return [Integer]
  def dim0; end

  # @overload dim1
  #   Returns `shape[1]`, or `nil` if `ndim < 2`.
  #   @return [Integer, nil]
  def dim1; end

  # @overload dim2
  #   Returns `shape[2]`, or `nil` if `ndim < 3`.
  #   @return [Integer, nil]
  def dim2; end

  # @overload dim3
  #   Returns `shape[3]`, or `nil` if `ndim < 4`.
  #   @return [Integer, nil]
  def dim3; end

  # @overload parent
  #   Returns the parent CArray of `self`, or `nil` if `self` has no
  #   parent (i.e. is an entity).
  #   @return [CArray, nil]
  def parent; end

  # @overload root_array
  #   Returns the array at the root of the view chain (the entity).
  #   Returns `self` if `self` is already an entity.
  #   @return [CArray]
  def root_array; end

  # @overload ancestors
  #   Returns the list of arrays in the view chain, ordered from root
  #   to `self`.
  #   @return [Array<CArray>]
  def ancestors; end

  # @!group Type inquiry

  # @overload data_class
  #   Returns the `data_class` of `self` if it is a Face that carries
  #   one (e.g. `CARecord`). Returns `nil` for non-Face arrays.
  #   @return [Class, nil]
  def data_class; end

  # @overload data_class=(klass)
  #   Always raises. `data_class` now lives on the Face tail
  #   (`CARecord`); use `CARecord.new(klass, *shape)` or
  #   `CARecord.wrap(entity, klass)` instead.
  #   @param klass [Class] unused.
  #   @return [void]
  #   @raise [ArgumentError] always.
  def data_class=(klass); end

  # @!endgroup

  # @!group State inquiry

  # @overload scalar?
  #   Returns `true` if `self` is a {CScalar}.
  #   @return [Boolean]
  def scalar?; end

  # @overload entity?
  #   Returns `true` if `self` is an entity array (not a virtual
  #   view).
  #   @return [Boolean]
  def entity?; end

  # @overload virtual?
  #   Returns `true` if `self` is a virtual array (a view, not an
  #   entity).
  #   @return [Boolean]
  def virtual?; end

  # @overload attached?
  #   Returns `true` if `self` is currently attached
  #   (`ptr != NULL`).
  #   @return [Boolean]
  def attached?; end

  # @overload empty?
  #   Returns `true` if `self` has zero elements.
  #   @return [Boolean]
  def empty?; end

  # @overload read_only?
  #   Returns `true` if `self` is read-only.
  #   @return [Boolean]
  def read_only?; end

  # @overload mask_array?
  #   Returns `true` if `self` is itself a mask array. (Not the same
  #   as "a masked array"; for that see {#has_mask?}.)
  #   @return [Boolean]
  def mask_array?; end

  # @overload value_array?
  #   Returns `true` if `self` is a value array (the `.value` view of
  #   a masked array).
  #   @return [Boolean]
  def value_array?; end

  # @!group Type inquiry

  # @overload face?
  #   Returns `true` if `self` is a Face view (`CA_FLAG_IS_FACE`
  #   set).
  #   @return [Boolean]
  def face?; end

  # @overload has_data_class?
  #   Returns `true` if `self` carries a `data_class` (i.e. is a Face
  #   such as `CARecord`).
  #   @return [Boolean]
  def has_data_class?; end

  # @overload fixlen?
  #   Returns `true` if `self` is a fixed-length type array.
  #   @return [Boolean]
  def fixlen?; end

  # @overload boolean?
  #   Returns `true` if `self` is a boolean type array.
  #   @return [Boolean]
  def boolean?; end

  # @overload numeric?
  #   Returns `true` if `self` is a numeric type array (any integer,
  #   float, or complex type).
  #   @return [Boolean]
  def numeric?; end

  # @overload integer?
  #   Returns `true` if `self` is an integer type array (signed or
  #   unsigned, any width).
  #   @return [Boolean]
  def integer?; end

  # @overload float?
  #   Returns `true` if `self` is a floating-point type array.
  #   @return [Boolean]
  def float?; end

  # @overload complex?
  #   Returns `true` if `self` is a complex type array.
  #   @return [Boolean]
  def complex?; end

  # @overload object?
  #   Returns `true` if `self` is an object type array
  #   (`data_type == :object`).
  #   @return [Boolean]
  def object?; end

  # @!endgroup
end
