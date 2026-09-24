#  What each numeric data type can hold, as constants on the typed
#  classes.
#
#      CArray::Int32::MAX        #  =>  2147483647
#      CArray::Float32::EPSILON  #  =>  1.1920928955078125e-07
#
#  The names follow NumPy's iinfo / finfo rather than Ruby's Float, so
#  that MIN and MAX bracket the range for every numeric type alike:
#
#      CArray::Float64::MIN      #  => -1.7976931348623157e+308
#      Float::MIN                #  =>  2.2250738585072014e-308
#
#  Those are not the same number and not the same question.  Ruby's
#  Float::MIN is the smallest positive normal, which is TINY here; MIN
#  is the bottom of the range, which for an integer type is the only
#  thing MIN could mean.  Code that has to bracket a type without
#  knowing whether it is integer or float reads MIN and MAX and is
#  right either way, and that is the reason for the choice.
#
#  Not every data type has limits.  boolean, fixlen and object have no
#  numeric range, so they carry none of these constants -- asking gives
#  a NameError rather than an answer that would have to be invented.

class CArray

  #  The integer widths come from the extension rather than from a table
  #  written here, so a platform where a type is not the usual width is
  #  described correctly instead of confidently mis-described.

  {
    Int8   => true,  Int16  => true,  Int32  => true,  Int64  => true,
    UInt8  => false, UInt16 => false, UInt32 => false, UInt64 => false,
  }.each do |klass, signed|
    bits = 8 * CArray.sizeof(klass::TypeSymbol)
    if signed
      klass.const_set(:MIN, -(2 ** (bits - 1)))
      klass.const_set(:MAX, 2 ** (bits - 1) - 1)
    else
      klass.const_set(:MIN, 0)
      klass.const_set(:MAX, 2 ** bits - 1)
    end
  end

  #  float32 and float64 are IEEE-754 binary32 and binary64, and the four
  #  values below follow from the format: with `p` significand bits (the
  #  implicit one included) and `emax` the exponent of the largest finite
  #  value,
  #
  #      EPSILON = 2 ** (1 - p)          the step from 1.0 to the next float
  #      MAX     = (2 - EPSILON) * 2 ** emax
  #      MIN     = -MAX                  every format here is symmetric
  #      TINY    = 2 ** (1 - emax)       the smallest positive normal
  #
  #  All four are exactly representable as a Ruby Float, binary32
  #  included, so nothing is rounded on the way in.  The width is
  #  checked rather than assumed: on a platform where C float or double
  #  is not one of these formats the arithmetic below would be wrong,
  #  and a wrong limit is worse than a missing one.

  {
    Float32 => [4, 24, 127],
    Float64 => [8, 53, 1023],
  }.each do |klass, (bytes, precision, max_exponent)|
    actual = CArray.sizeof(klass::TypeSymbol)
    unless actual == bytes
      raise "#{klass} is #{actual} bytes wide, not the #{bytes * 8}-bit IEEE-754 " \
            "format its limits are derived from"
    end
    epsilon = 2.0 ** (1 - precision)
    max     = (2.0 - epsilon) * 2.0 ** max_exponent
    klass.const_set(:EPSILON, epsilon)
    klass.const_set(:MAX,     max)
    klass.const_set(:MIN,     -max)
    klass.const_set(:TINY,    2.0 ** (1 - max_exponent))
  end

  #  A complex type is a pair of floats, so its limits are its
  #  component's -- MIN and MAX bound the real and the imaginary part
  #  separately, not any magnitude of the pair.  This is what
  #  np.finfo(np.complex64) answers too.

  {
    Complex64  => Float32,
    Complex128 => Float64,
  }.each do |klass, component|
    [:MIN, :MAX, :TINY, :EPSILON].each do |name|
      klass.const_set(name, component.const_get(name))
    end
  end

end
