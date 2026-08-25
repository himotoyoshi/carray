# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for the CAMath module functions defined in
# ext/carray_mathfunc.c.  Most CAMath entries (atan2 / hypot / expm1
# / log1p / copysign / logaddexp / nextafter / fmod / min / max) live
# in lib/carray/math.rb and are documented at the source.  This file
# covers only the C-defined module functions.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Namespace for math module functions that operate on CArray (and
# auto-wrappable scalar) inputs.
module CAMath
  module_function

  # @overload spherical_to_xyz(r, theta, phi)
  #   Returns three CArrays `[x, y, z]` of cartesian coordinates
  #   converted from spherical coordinates.  All inputs are coerced
  #   to `:float64`; outputs are `:float64`.
  #
  #   `theta` is the polar angle from the `+z` axis in radians;
  #   `phi` is the azimuthal angle in the `xy` plane in radians.
  #   @param r [CArray, Numeric] radial distance.
  #   @param theta [CArray, Numeric] polar angle (radians).
  #   @param phi [CArray, Numeric] azimuthal angle (radians).
  #   @return [Array<CArray>] `[x, y, z]`.
  def spherical_to_xyz(r, theta, phi); end

  # @overload xyz_to_spherical(x, y, z)
  #   Returns three CArrays `[r, theta, phi]` of spherical
  #   coordinates converted from cartesian coordinates.  All inputs
  #   are coerced to `:float64`; outputs are `:float64`.
  #   @param x [CArray, Numeric]
  #   @param y [CArray, Numeric]
  #   @param z [CArray, Numeric]
  #   @return [Array<CArray>] `[r, theta, phi]`.
  #   @raise [RuntimeError] when the build lacks `atan2`.
  def xyz_to_spherical(x, y, z); end

  # @overload lgamma(x)
  #   Returns a `:float64` CArray of `log(|Γ(x)|)` for each element of
  #   `x`.  `x` is coerced to `:float64`.
  #   @param x [CArray, Numeric]
  #   @return [CArray]
  #   @raise [RuntimeError] when the build lacks `lgamma`.
  def lgamma(x); end
end
