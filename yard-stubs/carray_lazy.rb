# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_lazy.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Zero-cost marker view that dispatches subsequent element-wise ops
# into the lazy CAMonOp / CABinOp tree instead of evaluating eagerly.
# Read-only; `.to_ca` materialises.
class CALazyMarker < CAView
end

class CArray
  # @!group Views
  # @overload lazy
  #   Returns a {CALazyMarker} view wrapping `self`.  Subsequent
  #   element-wise ops on the marker (`m.sqrt`, `m + 1`, ...) build
  #   a lazy expression tree; call `.to_ca` on the result to
  #   materialise.  The marker is transient — a Ruby reference can
  #   re-consume it (`m = a.lazy; m.sqrt + m.sin`) without side
  #   effects on `self`.
  #   @return [CALazyMarker]
  def lazy; end
  # @!endgroup
end

class CAMonOp
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A one-operand element-wise operation holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

class CABinOp
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A two-operand element-wise operation holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

class CATriOp
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A three-operand element-wise operation holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

class CAMonCmp
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A one-operand element-wise predicate holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

class CABinCmp
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A two-operand element-wise comparison holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

class CALazyMarker
  # @!group Copy and conversion

  # @overload to_ca
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   A lazy marker holds no data of its own, so there is nothing to
  #   hand over unevaluated: unlike `CArray#to_ca`, which returns
  #   `self`, this materialises -- the Ruby `Enumerable#to_a` /
  #   lazy `force` convention.
  #
  #   The entity is detached from the operands, so writes to it reach
  #   nothing. `writable: true` is therefore refused rather than
  #   answered with a result that would swallow them.
  #   @param writable [Boolean] whether the caller needs writes to
  #     land back in the source; only `false` can be satisfied.
  #   @return [CArray] a newly evaluated entity.
  #   @raise [RuntimeError] when `writable: true` is requested.
  def to_ca(writable: false); end

  # @overload copy
  #   Evaluates the expression and returns the result as a new entity.
  #
  #   If an expression evaluator is registered through
  #   {CArray.expression_evaluator} it is asked first; the ordinary
  #   element-wise walk is what happens when it declines, when none is
  #   registered, or when the array is small enough that walking is
  #   the faster answer.
  #   @return [CArray] a newly evaluated entity.
  def copy; end

  # @!endgroup
end

