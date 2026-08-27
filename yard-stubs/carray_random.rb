# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_random.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Random

  # @overload random!(rng: nil)
  #   A float array: samples `[0.0, 1.0)`.  An integer array: raises
  #   (a range is required).
  # @overload random!(high, rng: nil)
  #   Samples `[0, high)` (Ruby `rand` / Numo `.rand` shorthand).
  # @overload random!(low, high, rng: nil)
  #   Samples `[low, high)` (Numo positional convention).
  # @overload random!(range, rng: nil)
  #   Samples from a Ruby Range: `a..b` closed, `a...b` half-open.
  #   An integer array honors the endpoint distinction (dice: `1..6`
  #   yields values in `1..6` including 6; `1...6` yields `1..5`).
  #   For a float array, closed and half-open are equivalent at the
  #   sampler level (endpoint probability ≈ 2^-53), matching
  #   NumPy/SciPy convention — `..` is accepted for syntax but the
  #   endpoint is not enforced at the mantissa.
  #
  #   Fills `self` with uniform random numbers in-place and returns
  #   `self`.  Boolean arrays fill 0/1 at 50% probability, ignoring
  #   any range argument.  Complex arrays sample real and imaginary
  #   parts independently from the same range.
  #
  #   @param low [Numeric] lower bound (inclusive).
  #   @param high [Numeric] upper bound (exclusive).
  #   @param range [Range] closed (`a..b`) or half-open (`a...b`).
  #   @param rng [Random, nil] RNG instance; nil uses the per-ractor
  #     default RNG.
  #   @return [self]
  #   @raise [CArray::DataTypeError] for `:object` / `:fixlen` arrays.
  #   @raise [ArgumentError] when an integer array is called with no
  #     range, when `low >= high`, when a Range is combined with a
  #     second positional argument, or when a Range endpoint is nil.
  def random!(*args, rng: nil); end

  # @overload random(rng: nil)
  # @overload random(high, rng: nil)
  # @overload random(low, high, rng: nil)
  # @overload random(range, rng: nil)
  #   Non-bang variant: returns a newly templated array filled by
  #   `random!`.  Accepts the same argument forms.
  #   @return [CArray]
  def random(*args, rng: nil); end

  # @overload randomn!(rng: nil)
  #   Fills `self` with standard normal `N(0, 1)` samples via
  #   Box-Muller and returns `self`. Restricted to float / complex
  #   data types; complex fills real and imaginary parts as two
  #   independent normals per cell.
  #   @param rng [Random, nil] RNG instance; nil uses the per-ractor
  #     default RNG.
  #   @return [self]
  #   @raise [CArray::DataTypeError] for non-float / non-complex arrays.
  def randomn!(rng: nil); end

  # @overload randomn(rng: nil)
  #   Non-bang variant: returns a newly templated array filled by
  #   `randomn!`.
  #   @return [CArray]
  def randomn(rng: nil); end

  # @!endgroup

  # @!group Random

  # @overload shuffle!(axis: nil, rng: nil)
  #   Fisher-Yates permutes `self` in-place and returns `self`.
  #   Without `axis:`, shuffles all cells as if flattened. With
  #   `axis:`, permutes slices along that axis (the trailing
  #   sub-slab is treated as a byte chunk and swapped whole).
  #   @param axis [Integer, nil] axis to permute along; nil = flat.
  #   @param rng [Random, nil] RNG instance; nil uses the per-ractor
  #     default RNG.
  #   @return [self]
  #   @raise [ArgumentError] if `axis` is out of range.
  def shuffle!(axis: nil, rng: nil); end

  # @overload shuffle(axis: nil, rng: nil)
  #   Non-bang variant: returns a shuffled copy of `self`.
  #   @return [CArray]
  def shuffle(axis: nil, rng: nil); end

  # @!endgroup
end
