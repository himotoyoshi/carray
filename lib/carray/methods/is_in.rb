class CArray

  # @overload is_in(values)
  #   Returns a boolean CArray of the same shape as `self`, `true` at
  #   each cell whose value appears in the set `values`.
  #
  #   `values` is treated as a set, not as an operand to broadcast: it
  #   may be any shape (or an Array / Range) and is flattened to a
  #   single seen-set, so its shape need not match `self`. Only one
  #   argument is accepted; to test a few immediate values pass an
  #   Array (`a.is_in([0, -1])`).
  #
  #   When `self` and `values` have different numeric data types they are
  #   promoted to a common type first (the same promotion binops use,
  #   {CArray.result_type}), so membership is value-correct across
  #   data types (e.g. an int cell equals a float set element of the same
  #   value, and a fractional set element never truncates onto an int
  #   cell). Integers of mixed sign are matched by value, as {#eq}
  #   compares them: `-1` in an int8 array never matches `255` in a uint8
  #   one, and the set operations answer such a pair in a type that holds
  #   both (int16 for uint8 with int8, object for uint64 with int64).
  #   Genuinely incompatible data types (e.g. numeric vs fixlen) raise.
  #
  #   Membership is value-based and shares the distinctness of the
  #   value-hash discovery family ({#unique} / {#value_counts}):
  #   numeric follows `==` with all NaN collapsed to one value and
  #   -0.0 == +0.0; `CA_OBJECT` follows Ruby `hash` / `eql?` with Float
  #   NaN collapsed; `CA_FIXLEN` follows byte equality over the whole
  #   cell, with a short String in the set padded out to the cell width
  #   (so a 5-byte array written from `"be"` is `is_in(["be"])`). A
  #   `CA_FIXLEN` set given as a CArray must already be of that width.
  #
  #   An object array keeps Ruby's own split between its two kinds of
  #   equality. A lookup through a hash -- `is_in`, the set operations,
  #   {#locate_addr}, {#unique} and the rest of the discovery family --
  #   uses `eql?`, as `Array#uniq`, `Array#&` and `Set` do, so `1` and
  #   `1.0` are different values there. A cell-by-cell comparison --
  #   {#eq}, {#count}, {#search}, {#bsearch} -- uses `==`, as
  #   `Array#include?` does, so they are equal there. To match by value
  #   across Integer and Float, convert the array to a numeric type first.
  #
  #   Masked cells of `values` do not enter the set. Masked cells of
  #   `self` stay masked in the result (membership is unknown), so
  #   `is_in` propagates `self`'s mask like an element-wise comparison.
  #
  #   For a per-fiber "does this fiber contain any of these values"
  #   reduction, compose with {#any}: `a.is_in(values).any(axis: k)`.
  #
  #   @param values [CArray, Array, Range] the set to test membership
  #     against. Promoted with `self` to a common data type.
  #   Between two time arrays the question is about instants, not ticks:
  #   `values` is reconciled into `self`'s unit first, so a `:D` array and an
  #   `:h` array match on the instants they share.  The same holds for the set
  #   operations below, whose results come back as `self`'s own type.
  #
  #   @return [CArray] boolean CArray of the same shape as `self`.
  def is_in (values)
    a, b = promote_value_set(values)
    a.__send__(:__is_in__, b)
  end

  # @overload intersection(other, sort: false)
  #   Returns a 1-D CArray of the distinct values appearing in both
  #   `self` and `other`, in `self`'s first-appearance order.
  #
  #   Value-based, sharing the distinctness of the discovery family
  #   (see {#is_in}); `self` and `other` are promoted to a common data type.
  #   Masked cells of either array do not participate. The result is
  #   always flat, like {#unique}, because the distinct values of a
  #   fiber vary in number.
  #
  #   @param other [CArray, Array, Range] promoted with `self`.
  #   @param sort [Boolean] when true, return the values sorted
  #     ascending instead of in first-appearance order.
  #   @return [CArray] 1-D CArray of the common distinct values.
  def intersection (other, sort: false)
    a, b = promote_value_set(other)
    r = a.__send__(:__intersection__, b)
    r = r.to_unit(unit) if !a.equal?(self) && respond_to?(:in_common_unit_with)
    sort ? r.sort : r
  end

  # @overload difference(other, sort: false)
  #   Returns a 1-D CArray of the distinct values in `self` that are
  #   absent from `other`, in `self`'s first-appearance order.
  #   See {#intersection} for the shared semantics and options.
  #
  #   @param other [CArray, Array, Range] promoted with `self`.
  #   @param sort [Boolean] when true, return the values sorted ascending.
  #   @return [CArray] 1-D CArray of the self-only distinct values.
  def difference (other, sort: false)
    a, b = promote_value_set(other)
    r = a.__send__(:__difference__, b)
    r = r.to_unit(unit) if !a.equal?(self) && respond_to?(:in_common_unit_with)
    sort ? r.sort : r
  end

  # @overload union(other, sort: false)
  #   Returns a 1-D CArray of the distinct values appearing in either
  #   `self` or `other`, in self-then-other first-appearance order.
  #   See {#intersection} for the shared semantics and options.  Two time
  #   arrays of different units give their union in the finer unit, which
  #   holds the values of both ({#intersection} and {#difference} answer in
  #   `self`'s unit, since their values are `self`'s).
  #
  #   @param other [CArray, Array, Range] promoted with `self`.
  #   @param sort [Boolean] when true, return the values sorted ascending
  #     (a merged, ordered set — e.g. a common time axis).
  #   @return [CArray] 1-D CArray of the combined distinct values.
  def union (other, sort: false)
    a, b = promote_value_set(other)
    r = a.__send__(:__union__, b)
    sort ? r.sort : r
  end

  private

  # Reconcile a set-valued argument with self to a common data_type via
  # CArray.result_type (the single-source promotion rule the eager binop and
  # lazy CABinOp share), returning [self', set']. Only data types are reconciled,
  # never shapes: unlike the binop coercion (cast_self_or_other) the set's
  # shape never broadcasts against self's, so a size-1 self keeps its shape.
  # result_type raises for genuinely incompatible data types (numeric vs fixlen).
  #
  # A bare Array / Range has no intrinsic data type, so the common type is inferred
  # from self and the individual elements (result_type classifies each scalar).
  # This keeps a fractional literal from truncating onto an int self, and an
  # int literal from boxing a float self into the object lane (where Float 2.0
  # is not eql? Integer 2). A CArray argument uses its own data type; any other
  # operand (Numo, a MemoryView producer, ...) comes in through wrap_readonly,
  # the canonical type-coercion entry, so its format's data type drives the promote.
  def promote_value_set (values)
    # Two time arrays of different units meet in the finer one.
    if values.is_a?(CArray) && values.class == self.class &&
       respond_to?(:in_common_unit_with)
      return in_common_unit_with(values)
    end
    values = values_for_lookup(values) if values.is_a?(CArray)
    # Two fixed-width string arrays of different widths meet at the wider.
    if values.is_a?(CArray) && data_type == CA_FIXLEN && values.data_type == CA_FIXLEN
      return fixlen_widened_with(values)
    end
    # A Face that reconciles operands (CATime) reads a bare Array as values
    # of its own kind -- instants written as Time / String / elements.
    if values.is_a?(Array) && face? && respond_to?(:to_comparable)
      return [self, to_comparable(values)]
    end
    # ...and so does an array of values that are not of its kind (an object
    # column of Time values, a string column).
    if values.is_a?(CArray) && respond_to?(:to_comparable) &&
       !values.respond_to?(:to_comparable)
      return [self, values_in_face(self, values) || to_comparable([])]
    end
    # The same from the other side: values of a time array looked for in an
    # array that is not one.
    if values.is_a?(CArray) && values.respond_to?(:to_comparable) &&
       !respond_to?(:to_comparable)
      return [values_in_face(values, self) || values.to_comparable([]), values]
    end
    case values
    when Array then return promote_elements(values)
    when Range then return promote_elements(values.to_a)
    end
    set = values.is_a?(CArray) ? values : CArray.wrap_readonly(values)
    return [self, set] if set.data_type == data_type   # common fast path
    t = value_match_type(CArray.result_type(self, set), set.data_type)
    [coerce_self(t), set.to_type(t)]
  end

  # Bare Array / Range against numeric self: infer the common numeric type
  # from self and the elements (each classified by result_type), so a
  # fractional literal promotes self to float instead of truncating. Against
  # object / fixlen self the elements are values, not data type specifiers (a
  # String is a value, not a type name), so build the set in self's data type.
  def promote_elements (elems)
    if data_type == CA_FIXLEN
      # A fixlen value is a cell-width blob, so the set has to be built at
      # this array's width -- to_type(:fixlen) with no bytes: builds it at
      # width 0, where every element is "" and the C guard then refuses the
      # set for not matching self.  Same rule the scalar operand of a
      # comparison follows: a String standing in for a cell is padded to the
      # cell's width.
      [self, elems.to_ca.to_type(data_type, bytes: bytes)]
    elsif data_type == CA_OBJECT
      [self, elems.to_ca.to_type(data_type)]
    else
      t = CArray.result_type(self, *elems)
      t = value_match_type(t, CA_INT64) if elems.any? { |v| v.is_a?(Integer) && v < 0 }
      [coerce_self(t), elems.to_ca.to_type(t)]
    end
  end

  # +other+ as a lookup against self reads it.  A string array whose cells
  # hold ranges into a pool of its own (CAConstString) is read by its
  # strings, and a categorical by its labels, since their storage is not
  # their values; anything else, or the same kind of array as self, is
  # taken as it is.  A record is left to be refused.
  def values_for_lookup (other)
    return other if other.send(:__orderable_storage__)
    return other if face? && other.class == self.class
    if other.respond_to?(:to_string)
      other.to_string
    elsif other.is_a?(CACategorical)
      other.to_type(:object)
    else
      other
    end
  end

  # [self, other] at one cell width when both are fixed-width string arrays
  # (CAFixlenString) of different widths: the narrower is padded with NUL to
  # the wider, as concatenate joins them, so a string matches whatever width
  # it is held at.  Raw fixlen cells of different widths are values of
  # different lengths, not padded strings, and are left as they are (the
  # lookup refuses them, naming the widths).
  def fixlen_widened_with (other)
    return [self, other] if bytes == other.bytes
    return [self, other] unless is_a?(CAFixlenString) && other.is_a?(CAFixlenString)
    w = [bytes, other.bytes].max
    [widen_fixlen_string(self, w), widen_fixlen_string(other, w)]
  end

  def widen_fixlen_string (x, w)
    x.bytes == w ? x : x.to_fixlen_string(bytes: w)
  end

  # The values of +other+, which has no to_comparable, read as values of +face+'s
  # kind (instants written as Time / Date / String for a time key), in an
  # array of +other+'s shape; a masked cell stays masked.  nil when every
  # cell is masked: there is nothing to read.
  private def values_in_face(face, other)
    return face.to_comparable(other) if other.is_a?(Array)
    vals = other.flatten.to_a
    filler = vals.find { |v| !UNDEF.equal?(v) }
    return nil if filler.equal?(nil) && vals.all? { |v| UNDEF.equal?(v) }
    out = face.to_comparable(vals.map { |v| UNDEF.equal?(v) ? filler : v })
    out[other.is_masked.flatten] = UNDEF if other.has_mask?
    out.reshape(*other.shape)
  end

  def coerce_self (t)
    CArray.result_type(self) == t ? self : to_type(t)
  end

end
