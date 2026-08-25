# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for the UNDEF sentinel and UndefClass defined in
# ext/carray_undef.c. See yard-stubs/README.md and yard-stubs/STYLE.md.

# Singleton class of the {UNDEF} sentinel value.  Not instantiable
# (`UndefClass.new` is undef'd after the single instance is created
# in `Init_carray_undef`).
#
# The class is private API in practice: read and write the sentinel
# through the top-level `UNDEF` constant rather than touching the
# class directly.
class UndefClass
  # @overload inspect
  #   Returns the literal string `"UNDEF"`.
  #   @return [String]
  def inspect; end

  # @overload to_s
  #   Returns the literal string `"UNDEF"`.  Display works (so
  #   `puts UNDEF` shows `"UNDEF"`); numeric coercion via {#to_f}
  #   / {#to_i} raises.
  #   @return [String]
  def to_s; end

  # @overload to_f
  #   Raises `TypeError`.  Numeric coercion of UNDEF is rejected so
  #   that accidental arithmetic on a masked sentinel surfaces as an
  #   error rather than silently producing `0.0` / `NaN`.
  #   @raise [TypeError]
  def to_f; end

  # @overload to_i
  #   Raises `TypeError`.  Same rationale as {#to_f}.
  #   @raise [TypeError]
  def to_i; end

  # @overload to_int
  #   Alias of {#to_i}.  Raises `TypeError`.
  #   @raise [TypeError]
  def to_int; end

  # @overload ==(other)
  #   Returns `true` only when `other` is the same UNDEF singleton
  #   (identity comparison).  No coercion or value equality.
  #   @param other [Object]
  #   @return [Boolean]
  def ==(other); end
end

# Top-level sentinel used by mask-bearing CArray APIs to mean
# "masked / no value here" without choosing a numeric sentinel
# (NaN, `-1`, etc.) that might collide with valid data.
#
# Identity semantics: every reference to `UNDEF` is the same Ruby
# object, pinned against the compacting GC so the C extension can
# safely use raw pointer comparison to detect it.
#
# @example mask a cell during construction
#   a = CArray.int32(3) { |i| (i == 1) ? UNDEF : i * 10 }
#   a.to_a  # => [0, nil, 20]    # UNDEF surfaces as nil after to_a
#
# @example check whether an element is masked
#   a[1] == UNDEF  # => true
UNDEF = UndefClass.new
