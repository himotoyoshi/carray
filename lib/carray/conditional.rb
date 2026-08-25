# ----------------------------------------------------------------------------
#
#  carray/conditional.rb
#
#  Element-wise conditional selection primitives.  Three flavours share the
#  same "pick a value per cell based on a boolean condition" contract but
#  differ in where the condition lives and how the branches are supplied:
#
#      cond.then_else(x, y)                  # boolean receiver, 2 values (eager)
#      self.replace_where(cond, b)           # value receiver, 1 replacement (eager)
#      self.conditional(cond, f_then, f_else) # value receiver, 2 callables (per-region)
#
#  `then_else` and `replace_where` evaluate both branches over the full array
#  and pick per cell — fast but requires every branch to be domain-safe over
#  the whole receiver.  `conditional` extracts the two subsets first and
#  applies each callable only to its own region, which is domain-safe by
#  construction (e.g. `x.log` is never evaluated on negative cells).
#
# ----------------------------------------------------------------------------

class CArray

  # @overload then_else(x, y)
  #   Returns a ternary selection on `self` (a boolean CArray),
  #   reading as "if `self` then `x` else `y`". The boolean 2-way
  #   case of {#choose} that additionally propagates `self`'s mask
  #   (`UNDEF` in `self` produces `UNDEF` in the result).
  #   @param x [CArray, Numeric, Object] true-branch value(s).
  #   @param y [CArray, Numeric, Object] false-branch value(s).
  #   @return [CArray] new array with the same shape as `self`.
  #   @raise [ArgumentError] when `self` is not a boolean CArray.
  def then_else (x, y)
    # Guard: self must be boolean.  Integer / float receiver would be
    # silently reinterpreted by the indexer setter (`result[self] = ...`)
    # as an index array, producing surprising scatter rather than the
    # intended ternary select.  Fail fast.
    unless self.boolean?
      raise ArgumentError,
            "then_else: receiver must be a boolean CArray (data_type == CA_BOOLEAN), got #{self.data_type}"
    end
    # Promote data_type from both branches via CArray.result_type
    # (a CScalar contributes its own data_type, so CA_INT32(0) keeps int32
    # where a bare Ruby Integer would widen to int64).
    dt = CArray.result_type(x, y)
    # A CScalar (scalar? CArray) is treated as a scalar value, not as a
    # self-shaped operand: full CArray -> gather/copy, scalar -> broadcast.
    y_full = y.is_a?(CArray) && !y.scalar?
    result =
      if y_full
        y.data_type == dt ? y.copy : y.to_type(dt)
      else
        CArray.new(dt, self.shape).fill(y.is_a?(CArray) ? y[0] : y)
      end
    x_full = x.is_a?(CArray) && !x.scalar?
    result[self] = x_full ? x[self] : x
    # Propagate cond's mask: UNDEF in self -> UNDEF in result.
    if self.has_mask?
      result[self.is_masked] = UNDEF
    end
    result
  end

  # @overload replace_where(cond, b)
  #   Returns a copy of `self` with cells where `cond` is true
  #   replaced by `b`. Functional sibling of the destructive
  #   indexer `a[cond] = b`; mask handling matches the indexer.
  #   Preserves `self`'s `data_type` (unlike {#then_else}, which
  #   promotes via `CArray.result_type`).
  #   @param cond [CArray] boolean selector; same shape as `self`
  #     or broadcastable.
  #   @param b [CArray, Numeric, Object] replacement value(s).
  #   @return [CArray] new array.
  #   @raise [ArgumentError] when `cond` is not a boolean CArray.
  def replace_where (cond, b)
    unless cond.is_a?(CArray) && cond.boolean?
      raise ArgumentError,
            "replace_where: cond must be a boolean CArray (data_type == CA_BOOLEAN)"
    end
    result = self.copy
    result[cond] = b.is_a?(CArray) ? b[cond] : b
    result
  end

  # @overload conditional(cond, then_fn, else_fn, dtype: nil)
  #   Returns per-cell `then_fn.call(self[cond])` where `cond` is
  #   true and `else_fn.call(self[cond.not])` where it is false.
  #   The two callables are applied only to their own subset of
  #   `self`, so a branch that would fail on the other region
  #   (e.g. `->(v) { v.log }` on negative cells) stays safe.
  #
  #   Scalar returns from a callable (e.g. `->(v) { 0 }`) broadcast
  #   to the subset shape. The result `data_type` is the promotion
  #   of the two subset results via `CArray.result_type`, or
  #   `dtype` when given. Masked cells in `cond` propagate to
  #   `UNDEF` in the result.
  #
  #   @param cond [CArray] boolean selector; same shape as `self`.
  #   @param then_fn [#call] callable applied to `self[cond]`.
  #   @param else_fn [#call] callable applied to `self[cond.not]`.
  #   @param dtype [Symbol, Integer, nil] override for the result
  #     `data_type`.
  #   @return [CArray] new array with the same shape as `self`.
  #   @raise [ArgumentError] when `cond` is not a same-shape
  #     boolean CArray.
  #   @example
  #     x = CArray.float64(6).span(-2.0..3.0)
  #     x.conditional(x > 0,
  #                   ->(v) { v.log },        # domain-safe: only positive cells
  #                   ->(v) { -v })
  #     # => [2.0, 1.0, -0.0, 0.0, 0.6931..., 1.0986...]
  def conditional (cond, then_fn, else_fn, dtype: nil)
    unless cond.is_a?(CArray) && cond.boolean? && cond.shape == self.shape
      raise ArgumentError,
            "conditional: cond must be a boolean CArray with same shape as self"
    end

    x_then = self[cond]
    x_else = self[cond.not]
    y_then = then_fn.call(x_then)
    y_else = else_fn.call(x_else)

    # A callable that returns a scalar (e.g. `->(v) { 0 }`) broadcasts
    # to the subset shape; wrap it here so the scatter step below sees a
    # same-length CArray.
    unless y_then.is_a?(CArray)
      y_then = CArray.new(dtype || CArray.result_type(y_then), x_then.shape).fill(y_then)
    end
    unless y_else.is_a?(CArray)
      y_else = CArray.new(dtype || CArray.result_type(y_else), x_else.shape).fill(y_else)
    end

    dt  = dtype || CArray.result_type(y_then, y_else)
    out = CArray.new(dt, self.shape)
    out[cond]     = y_then
    out[cond.not] = y_else
    # Propagate cond's mask (mirrors then_else's rule): UNDEF in cond ->
    # UNDEF in out.  Kleene `cond.not` also carries UNDEF at the same
    # positions, so both scatters leave the cell untouched — an explicit
    # fix-up is required.
    out[cond.is_masked] = UNDEF if cond.has_mask?
    out
  end

  # @overload select(condlist, choicelist, default: 0, dtype: nil)
  #   Multi-way ternary select: for each cell, picks the value from
  #   the first `choicelist[k]` whose matching `condlist[k]` is true,
  #   falling back to `default` when no condition holds. When several
  #   conditions overlap, the earliest one in `condlist` wins.
  #
  #   All entries in `condlist` must be same-shape boolean CArrays.
  #   Each `choicelist[k]` is either a same-shape CArray or a scalar
  #   broadcast to every cell. The result `data_type` is the promotion
  #   of every choice plus `default` via `CArray.result_type`, or
  #   `dtype` when given.
  #
  #   @param condlist [Array<CArray>] boolean selectors.
  #   @param choicelist [Array<CArray, Numeric, Object>] values, one
  #     per condition (same length as `condlist`).
  #   @param default [CArray, Numeric, Object] value written where no
  #     condition holds.
  #   @param dtype [Symbol, Integer, nil] override for the result
  #     `data_type`.
  #   @return [CArray] new array with the shape of `condlist[0]`.
  #   @raise [ArgumentError] on size mismatch, empty `condlist`, or a
  #     non-boolean / wrong-shape entry in `condlist`.
  #   @example
  #     x = CArray.float64(6).span(-5.0..5.0)
  #     CArray.select([x < 0, x < 2],
  #                   [-x,    x * 10],
  #                   default: 999)
  #     # => [5.0, 3.0, -10.0, 0.0, 10.0, 999.0]
  def self.select (condlist, choicelist, default: 0, dtype: nil)
    unless condlist.is_a?(Array) && choicelist.is_a?(Array)
      raise ArgumentError, "select: condlist and choicelist must be Arrays"
    end
    if condlist.size != choicelist.size
      raise ArgumentError,
            "select: condlist (#{condlist.size}) and choicelist (#{choicelist.size}) size mismatch"
    end
    if condlist.empty?
      raise ArgumentError, "select: at least one condition required"
    end

    first = condlist.first
    unless first.is_a?(CArray) && first.boolean?
      raise ArgumentError, "select: condlist[0] must be a boolean CArray"
    end
    shape = first.shape

    dt = dtype || CArray.result_type(*choicelist, default)
    # `default` can be either a same-shape CArray (per-cell fallback) or a
    # scalar (broadcast to every cell).
    default_full = default.is_a?(CArray) && !default.scalar?
    out =
      if default_full
        default.data_type == dt ? default.copy : default.to_type(dt)
      else
        CArray.new(dt, shape).fill(default.is_a?(CArray) ? default[0] : default)
      end

    # Iterate from lowest priority to highest (reverse) so the earliest
    # entry in `condlist` ends up on top — matches `np.select`'s
    # first-match semantics.
    (condlist.size - 1).downto(0) do |k|
      c = condlist[k]
      unless c.is_a?(CArray) && c.boolean? && c.shape == shape
        raise ArgumentError,
              "select: condlist[#{k}] must be a same-shape boolean CArray"
      end
      v = choicelist[k]
      out[c] = v.is_a?(CArray) ? v[c] : v
    end
    out
  end

end
