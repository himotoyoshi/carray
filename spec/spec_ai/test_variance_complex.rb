# variance/variancep/stddev/stddevp complex support via reduce DSL Hash
# form expr.  Math:
#   Real:    Var(X) = E[X^2] - E[X]^2
#   Complex: Var(X) = E[|X|^2] - |E[X]|^2   (always non-negative real)
# Output data_type f64 in both cases.  Accumulator state acc uses Hash state-
# type form {numeric: :f64, complex: :cmplx128} to hold the partial sum
# in the appropriate width.  sumsq is f64 (sum of magnitude-squared).
#
# Mirrors monop/binop expr: Hash form and the output: Hash form already
# established; first reduce kernel to use Hash form for state-type +
# reduce-body + finish-body simultaneously.

require 'test/unit'
require 'carray'

class TestVarianceComplex < Test::Unit::TestCase
  EPS = 1e-12

  # ---- real-numeric path: regression check ----

  def test_variancep_real_parity
    a = CArray.float64(5).seq + 1.0   # [1,2,3,4,5], mean = 3
    # Var_p = ((1-3)^2 + ... + (5-3)^2)/5 = (4+1+0+1+4)/5 = 2.0
    assert_in_delta(2.0, a.variancep, EPS)
  end

  def test_variance_real_parity
    a = CArray.float64(5).seq + 1.0
    # Var_s (Bessel) = 10/4 = 2.5
    assert_in_delta(2.5, a.variance, EPS)
  end

  def test_stddevp_real_parity
    a = CArray.float64(5).seq + 1.0
    assert_in_delta(Math.sqrt(2.0), a.stddevp, EPS)
  end

  def test_stddev_real_parity
    a = CArray.float64(5).seq + 1.0
    assert_in_delta(Math.sqrt(2.5), a.stddev, EPS)
  end

  def test_int_variance_widens_to_f64
    a = CArray.int32(5).seq + 1
    r = a.variancep
    assert_equal(Float, r.class)
    assert_in_delta(2.0, r, EPS)
  end

  # ---- complex: unit circle ----

  def test_variancep_complex_unit_circle
    # 4 points on unit circle, mean = 0, |x|^2 each = 1
    # Var = E[|X|^2] - |E[X]|^2 = 1 - 0 = 1.0
    a = CArray.cmplx128(4)
    [Complex(1,0), Complex(0,1), Complex(-1,0), Complex(0,-1)].each_with_index { |v,i| a[i] = v }
    r = a.variancep
    assert_equal(Float, r.class)   # complex variance is real
    assert_in_delta(1.0, r, EPS)
  end

  def test_stddevp_complex_unit_circle
    a = CArray.cmplx128(4)
    [Complex(1,0), Complex(0,1), Complex(-1,0), Complex(0,-1)].each_with_index { |v,i| a[i] = v }
    assert_in_delta(1.0, a.stddevp, EPS)
  end

  # ---- complex: scaled circle (= variance scales as |scale|^2) ----

  def test_variancep_complex_scaled_circle
    a = CArray.cmplx128(4)
    [Complex(2,0), Complex(0,2), Complex(-2,0), Complex(0,-2)].each_with_index { |v,i| a[i] = v }
    # scale 2x → |x|^2 = 4 each → Var = 4
    assert_in_delta(4.0, a.variancep, EPS)
  end

  # ---- complex: non-zero mean ----

  def test_variancep_complex_nonzero_mean
    # X = c + r * exp(i theta_k), 4 points uniform on circle of radius r
    # Mean = c, |X|^2 = c.conj*c + 2*Re(c.conj*r*e^itheta) + r^2
    # E[|X|^2] = |c|^2 + 0 + r^2 (because uniform theta) = |c|^2 + r^2
    # |E[X]|^2 = |c|^2
    # Var = r^2 (= the variance of just the radius part)
    c0 = Complex(3, 4)   # |c0|^2 = 25
    r = 2.0
    a = CArray.cmplx128(4)
    4.times do |k|
      theta = 2 * Math::PI * k / 4
      a[k] = c0 + r * Complex(Math.cos(theta), Math.sin(theta))
    end
    # Var should be r^2 = 4
    assert_in_delta(r ** 2, a.variancep, 1e-9)
  end

  # ---- complex: variance is always non-negative ----

  def test_variancep_complex_always_non_negative
    a = CArray.cmplx128(10)
    10.times { |i| a[i] = Complex(rand - 0.5, rand - 0.5) }
    assert_operator(a.variancep, :>=, 0.0)
  end

  # ---- per-axis complex ----

  def test_variancep_complex_per_axis
    m = CArray.cmplx128(2, 4)
    [[Complex(1,0), Complex(0,1), Complex(-1,0), Complex(0,-1)],
     [Complex(2,0), Complex(0,2), Complex(-2,0), Complex(0,-2)]].each_with_index do |row, i|
      row.each_with_index { |v,j| m[i,j] = v }
    end
    r = m.variancep(axis: 1)
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(1.0, r[0], EPS)
    assert_in_delta(4.0, r[1], EPS)
  end

  def test_stddev_complex_per_axis
    m = CArray.cmplx128(2, 4)
    [[Complex(1,0), Complex(0,1), Complex(-1,0), Complex(0,-1)],
     [Complex(2,0), Complex(0,2), Complex(-2,0), Complex(0,-2)]].each_with_index do |row, i|
      row.each_with_index { |v,j| m[i,j] = v }
    end
    # variance(sample) = sum_sq / (n-1) - |mean|^2 * n/(n-1)
    # For row 0: 4/3 - 0 = 4/3 ≈ 1.333
    r = m.variance(axis: 1)
    assert_in_delta(4.0/3.0, r[0], EPS)
    assert_in_delta(16.0/3.0, r[1], EPS)
  end

  # ---- output data_type is f64 even for complex source ----

  def test_variancep_complex_output_is_f64
    # 2-D for per-axis output to be a CArray (not scalar)
    m = CArray.cmplx128(3, 4)
    3.times { |i| 4.times { |j| m[i, j] = Complex(i + j, i - j) } }
    r = m.variancep(axis: 1)
    assert_equal(:float64, r.data_type_name.to_sym)
  end

  # ---- bool raises (3.0 breaking from :wrap_to_f64 -> :raise); object
  #      is supported (see below + test_object_variance.rb) -------------

  def test_variancep_bool_numeric
    # 3.0: boolean variance = Bernoulli variance of the 0/1 storage (f64).
    a = CArray.boolean(3)
    [true, false, true].each_with_index { |v,i| a[i] = v }
    # [1,0,1]: mean 2/3, variancep = (2*(1/3)^2 + (2/3)^2)/3 = 2/9.
    assert_in_delta 2.0 / 9.0, a.variancep, 1e-12
  end

  # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH §4b (a): object variance is now
  # supported (accumulated exactly in the Ruby numeric tower, output
  # :object).  See test_object_variance.rb for the full contract.
  def test_variancep_object_supported
    a = CArray.object(3)
    [1, 2, 3].each_with_index { |v,i| a[i] = v }
    # [1,2,3]: (14 - 36/3)/3 = 2/3 -> Integer division = 0.
    assert_equal(0, a.variancep)
  end

  # ---- lazy chain ----

  def test_lazy_complex_variancep_parity
    n = 50
    a = CArray.cmplx128(n)
    b = CArray.cmplx128(n)
    n.times { |i| a[i] = Complex(Math.cos(i * 0.1), Math.sin(i * 0.1)) }
    n.times { |i| b[i] = Complex(0.1, 0.05) }
    expected = (a + b).variancep
    actual = (a.lazy + b).variancep
    assert_in_delta(expected, actual, 1e-9)
  end
end
