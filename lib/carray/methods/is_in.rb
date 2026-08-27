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
  #   cell). Genuinely incompatible data types (e.g. numeric vs fixlen)
  #   raise.
  #
  #   Membership is value-based and shares the distinctness of the
  #   value-hash discovery family ({#unique} / {#value_counts}):
  #   numeric follows `==` with all NaN collapsed to one value and
  #   -0.0 == +0.0; `CA_OBJECT` follows Ruby `hash` / `eql?` with Float
  #   NaN collapsed; `CA_FIXLEN` follows byte equality.
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
    sort ? r.sort : r
  end

  # @overload union(other, sort: false)
  #   Returns a 1-D CArray of the distinct values appearing in either
  #   `self` or `other`, in self-then-other first-appearance order.
  #   See {#intersection} for the shared semantics and options.
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
    case values
    when Array then return promote_elements(values)
    when Range then return promote_elements(values.to_a)
    end
    set = values.is_a?(CArray) ? values : CArray.wrap_readonly(values)
    return [self, set] if set.data_type == data_type   # common fast path
    t = CArray.result_type(self, set)
    [coerce_self(t), set.to_type(t)]
  end

  # Bare Array / Range against numeric self: infer the common numeric type
  # from self and the elements (each classified by result_type), so a
  # fractional literal promotes self to float instead of truncating. Against
  # object / fixlen self the elements are values, not data type specifiers (a
  # String is a value, not a type name), so build the set in self's data type.
  def promote_elements (elems)
    if data_type == CA_OBJECT || data_type == CA_FIXLEN
      [self, elems.to_ca.to_type(data_type)]
    else
      t = CArray.result_type(self, *elems)
      [coerce_self(t), elems.to_ca.to_type(t)]
    end
  end

  def coerce_self (t)
    CArray.result_type(self) == t ? self : to_type(t)
  end

end
