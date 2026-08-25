module CAMath

  module_function

  # Module-function front-ends for binop math methods registered on
  # CArray by mkkernel. The first argument is auto-wrapped to CArray
  # via `CArray.wrap_readonly`, so `CAMath.hypot(3, arr)` continues to
  # work. Integer input is unsupported at the kernel layer -- the
  # caller must cast to float64 explicitly (e.g.
  # `arr.as_float64.hypot(...)`).

  # @overload expm1(x)
  #   Returns `exp(x) - 1` element-wise as float64.
  #   @param x [CArray, Numeric] input value.
  #   @return [CArray]
  def expm1(x);  CArray.wrap_readonly(x, :float64).expm1;  end

  # @overload log1p(x)
  #   Returns `log(1 + x)` element-wise as float64.
  #   @param x [CArray, Numeric] input value.
  #   @return [CArray]
  def log1p(x);  CArray.wrap_readonly(x, :float64).log1p;  end

  # @overload atan2(y, x)
  #   Returns the element-wise arc tangent of `y / x` with quadrant
  #   selection.
  #   @param y [CArray, Numeric] numerator.
  #   @param x [CArray, Numeric] denominator.
  #   @return [CArray]
  def atan2(y, x);     CArray.wrap_readonly(y, :float64).atan2(x);     end

  # @overload hypot(x, y)
  #   Returns the element-wise Euclidean distance `sqrt(x^2 + y^2)`.
  #   @param x [CArray, Numeric] first leg.
  #   @param y [CArray, Numeric] second leg.
  #   @return [CArray]
  def hypot(x, y);     CArray.wrap_readonly(x, :float64).hypot(y);     end

  # @overload copysign(x, y)
  #   Returns `|x|` with the sign of `y`, element-wise.
  #   @param x [CArray, Numeric] magnitude source.
  #   @param y [CArray, Numeric] sign source.
  #   @return [CArray]
  def copysign(x, y);  CArray.wrap_readonly(x, :float64).copysign(y);  end

  # @overload logaddexp(x, y)
  #   Returns `log(exp(x) + exp(y))` computed to avoid overflow,
  #   element-wise.
  #   @param x [CArray, Numeric] first log-space value.
  #   @param y [CArray, Numeric] second log-space value.
  #   @return [CArray]
  def logaddexp(x, y); CArray.wrap_readonly(x, :float64).logaddexp(y); end

  # @overload nextafter(x, y)
  #   Returns the next representable float from `x` toward `y`,
  #   element-wise.
  #   @param x [CArray, Numeric] starting value.
  #   @param y [CArray, Numeric] direction target.
  #   @return [CArray]
  def nextafter(x, y); CArray.wrap_readonly(x, :float64).nextafter(y); end

  # @overload fmod(x, y)
  #   Returns the C-style `fmod(x, y)` element-wise (sign follows `x`).
  #   @param x [CArray, Numeric] dividend.
  #   @param y [CArray, Numeric] divisor.
  #   @return [CArray]
  def fmod(x, y);      CArray.wrap_readonly(x, :float64).fmod(y);      end

  # @overload min(*argv)
  #   Returns the element-wise minimum of the given CArray and other
  #   arguments. At least one argument must be a CArray.
  #   @param argv [Array<CArray, Numeric>] operands.
  #   @return [CArray] fresh CArray holding the running min.
  #   @raise [RuntimeError] when no CArray argument is present.
  def min (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.copy
      argv.delete(ary)
      argv.each do |x|
        out.pmin!(x)
      end
    else
      raise "args should contain more than one CArray object"
    end
    return out
  end

  # @overload max(*argv)
  #   Returns the element-wise maximum of the given CArray and other
  #   arguments. At least one argument must be a CArray.
  #   @param argv [Array<CArray, Numeric>] operands.
  #   @return [CArray] fresh CArray holding the running max.
  #   @raise [RuntimeError] when no CArray argument is present.
  def max (*argv)
    if ary = argv.find{|x| x.is_a?(CArray) }
      out = ary.copy
      argv.delete(ary)
      argv.each do |x|
        out.pmax!(x)
      end
    else
      raise "args should contain more than one CArray object"
    end
    return out
  end

end
