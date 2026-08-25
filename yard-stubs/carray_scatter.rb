# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_scatter.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Scatter and generation
  #
  # The `scatter_*!` family applies an in-place reduction at each
  # `addrs[i]` position from a paired `vals[i]` (or scalar). The
  # accumulate variants (`scatter_add!` / `scatter_sub!` /
  # `scatter_mul!` / `scatter_min!` / `scatter_max!`) apply duplicate
  # addresses in sequence (unbuffered). {#scatter_replace!} is the
  # last-write variant, equivalent to `self[addrs] = vals` but
  # bypasses the CAGrid view chain.
  #
  # Shared contract:
  #
  # - `addrs` is a CArray of any integer type (coerced to
  #   `CA_SIZE`) or a Ruby Array.
  # - `vals` is a CArray of length matching `addrs` (coerced to
  #   `self.data_type`), or a Numeric scalar broadcast to all
  #   addresses.
  # - Out-of-range `addrs[i]` (`< 0` or `>= self.elements`) raises
  #   `IndexError`.
  # - `self.data_type` must be numeric.
  #
  # Mask policy differs between the accumulate family and
  # {#scatter_replace!}: the accumulate variants skip the pair when
  # any of `addrs[i]`, `vals[i]`, or `self[addrs[i]]` is masked (an
  # unknown source can't accumulate). {#scatter_replace!} instead
  # overwrites the target (masked `vals[i]` flips the target to
  # masked, valid `vals[i]` clears the target's mask), matching the
  # `self[addrs] = vals` indexer.

  # @overload scatter_add!(addrs, vals)
  #   For each `i`, applies `self[addrs[i]] += vals[i]`
  #   (or `+= vals` if `vals` is scalar). Mutates `self`.
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric]
  #   @return [self]
  #   @raise [IndexError] for out-of-range addresses.
  #   @raise [CArray::DataTypeError] for non-numeric `data_type`.
  def scatter_add!(addrs, vals); end

  # @overload scatter_sub!(addrs, vals)
  #   For each `i`, applies `self[addrs[i]] -= vals[i]`. Same
  #   contract as {#scatter_add!}.
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric]
  #   @return [self]
  def scatter_sub!(addrs, vals); end

  # @overload scatter_mul!(addrs, vals)
  #   For each `i`, applies `self[addrs[i]] *= vals[i]`. Duplicate
  #   addresses multiply.
  #
  #   NaN/inf follow standard C arithmetic propagation (no
  #   `fmin`-style missing-value rule). Integer overflow wraps.
  #
  #   Typical uses: Bayesian likelihood patch update, scatter blend,
  #   log-domain → linear product, weight composition.
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric]
  #   @return [self]
  def scatter_mul!(addrs, vals); end

  # @overload scatter_min!(addrs, vals)
  #   For each `i`, applies
  #   `self[addrs[i]] = min(self[addrs[i]], vals[i])`.
  #
  #   For float `data_type`, NaN follows the `fmin` rule (NaN is
  #   treated as missing: `min(NaN, v) → v`, `min(x, NaN) → x`).
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric]
  #   @return [self]
  def scatter_min!(addrs, vals); end

  # @overload scatter_max!(addrs, vals)
  #   For each `i`, applies
  #   `self[addrs[i]] = max(self[addrs[i]], vals[i])`. For float
  #   `data_type`, NaN follows the `fmax` rule.
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric]
  #   @return [self]
  def scatter_max!(addrs, vals); end

  # @overload scatter_replace!(addrs, vals)
  #   For each `i`, applies `self[addrs[i]] = vals[i]` (or `= vals`
  #   if scalar). Duplicate addresses resolve to last-write-wins.
  #
  #   Semantically equivalent to `self[addrs] = vals` but bypasses
  #   the CAGrid view chain (which snapshot-copies `addrs` and
  #   allocates view state); useful in hot loops where a scatter
  #   result is written back many times.
  #
  #   Unlike the arithmetic `scatter_*!` family, `self` may be
  #   **boolean** (assignment does not widen), and `true` / `false`
  #   are accepted as scalar `vals` alongside numeric scalars.
  #
  #   @param addrs [CArray, Array<Integer>]
  #   @param vals [CArray, Numeric, true, false]
  #   @return [self]
  def scatter_replace!(addrs, vals); end

  # @!endgroup
end
