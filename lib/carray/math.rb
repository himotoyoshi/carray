module CAMath

  module_function

  # Module-function front-ends for binop math methods registered on
  # CArray by mkkernel.  A CArray first argument answers through its own
  # method, in its own data_type; any other first argument, and an
  # integer CArray for a function defined only on floats, is taken as
  # float64, so `CAMath.hypot(3, arr)` works.

  # @overload expm1(x)
  #   Returns `exp(x) - 1` element-wise.  A CArray answers in its own
  #   `data_type` (integer input widens to float64, as {CArray#expm1}
  #   does); any other value is taken as float64.
  #   @param x [CArray, Numeric] input value.
  #   @return [CArray]
  def expm1(x)
    x.is_a?(CArray) ? x.expm1 : CArray.wrap_readonly(x, :float64).expm1
  end

  # @overload log1p(x)
  #   Returns `log(1 + x)` element-wise.  A CArray answers in its own
  #   `data_type` (integer input widens to float64, as {CArray#log1p}
  #   does); any other value is taken as float64.
  #   @param x [CArray, Numeric] input value.
  #   @return [CArray]
  def log1p(x)
    x.is_a?(CArray) ? x.log1p : CArray.wrap_readonly(x, :float64).log1p
  end

  # @overload atan2(y, x)
  #   Returns the element-wise arc tangent of `y / x` with quadrant
  #   selection.
  #   @param y [CArray, Numeric] numerator.
  #   @param x [CArray, Numeric] denominator.
  #   @return [CArray]
  def atan2(y, x); float_operand(y).atan2(x); end

  # @overload hypot(x, y)
  #   Returns the element-wise Euclidean distance `sqrt(x^2 + y^2)`.
  #   @param x [CArray, Numeric] first leg.
  #   @param y [CArray, Numeric] second leg.
  #   @return [CArray]
  def hypot(x, y); float_operand(x).hypot(y); end

  # @overload copysign(x, y)
  #   Returns `|x|` with the sign of `y`, element-wise.
  #   @param x [CArray, Numeric] magnitude source.
  #   @param y [CArray, Numeric] sign source.
  #   @return [CArray]
  def copysign(x, y); float_operand(x).copysign(y); end

  # @overload logaddexp(x, y)
  #   Returns `log(exp(x) + exp(y))` computed to avoid overflow,
  #   element-wise.
  #   @param x [CArray, Numeric] first log-space value.
  #   @param y [CArray, Numeric] second log-space value.
  #   @return [CArray]
  def logaddexp(x, y); float_operand(x).logaddexp(y); end

  # @overload nextafter(x, y)
  #   Returns the next representable float from `x` toward `y`,
  #   element-wise.
  #   @param x [CArray, Numeric] starting value.
  #   @param y [CArray, Numeric] direction target.
  #   @return [CArray]
  def nextafter(x, y); float_operand(x).nextafter(y); end

  # @overload fmod(x, y)
  #   Returns the C-style `fmod(x, y)` element-wise (sign follows `x`).
  #   @param x [CArray, Numeric] dividend.
  #   @param y [CArray, Numeric] divisor.
  #   @return [CArray]
  def fmod(x, y);      (x.is_a?(CArray) ? x : CArray.wrap_readonly(x, :float64)).fmod(y); end

  # A float or complex CArray as it is; anything else as float64.
  def float_operand(x)
    x.is_a?(CArray) && (x.float? || x.complex?) ? x : CArray.wrap_readonly(x, :float64)
  end
  private_class_method :float_operand

  # @overload min(*argv)
  #   Returns the element-wise minimum of the given CArray and other
  #   arguments. At least one argument must be a CArray.
  #   @param argv [Array<CArray, Numeric>] operands.
  #   @return [CArray] fresh CArray holding the running min.
  #   @raise [ArgumentError] when no CArray argument is present.
  def min (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.copy
      argv.delete(ary)
      argv.each do |x|
        out.pmin!(x)
      end
    else
      raise ArgumentError, "args should contain more than one CArray object"
    end
    return out
  end

  # @overload max(*argv)
  #   Returns the element-wise maximum of the given CArray and other
  #   arguments. At least one argument must be a CArray.
  #   @param argv [Array<CArray, Numeric>] operands.
  #   @return [CArray] fresh CArray holding the running max.
  #   @raise [ArgumentError] when no CArray argument is present.
  def max (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.copy
      argv.delete(ary)
      argv.each do |x|
        out.pmax!(x)
      end
    else
      raise ArgumentError, "args should contain more than one CArray object"
    end
    return out
  end

end
