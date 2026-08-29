# Floored division and modulo (3.0).
#
# `/` and `%` follow Ruby (and NumPy's `floor_divide` / `mod`): integer
# division floors toward -inf and the remainder carries the sign of the
# divisor.  The truncating pair that C gives is reached through `fmod`.
#
#   - integer `/` floors, so `(a / b) * b + a % b == a` holds for every
#     sign combination -- as in Ruby
#   - float `/` stays true division, so that identity does not hold for
#     floats -- also as in Ruby
#   - every data type agrees, object arrays included

require "test/unit"
require "carray"

class TestFloorDivisionSemantics < Test::Unit::TestCase

  SIGN_CASES = [[-7, 3], [-1, 3], [7, 3], [-7, -3], [7, -3], [5, 3], [6, 3]]

  def test_integer_div_matches_ruby
    SIGN_CASES.each do |a, b|
      assert_equal(a / b, (CA_INT32([a]) / b)[0], "#{a} / #{b}")
    end
  end

  def test_integer_mod_matches_ruby
    SIGN_CASES.each do |a, b|
      assert_equal(a % b, (CA_INT32([a]) % b)[0], "#{a} % #{b}")
    end
  end

  def test_integer_div_mod_identity
    SIGN_CASES.each do |a, b|
      q = (CA_INT32([a]) / b)[0]
      r = (CA_INT32([a]) % b)[0]
      assert_equal(a, q * b + r, "(a / b) * b + a % b for #{a}, #{b}")
    end
  end

  def test_named_forms_track_the_operators
    a = CA_INT32([-7, -1, 7])
    assert_equal((a / 3).to_a, a.div(3).to_a)
    assert_equal((a % 3).to_a, a.mod(3).to_a)
  end

  def test_all_integer_data_types_agree
    [:int8, :int16, :int32, :int64].each do |dt|
      a = CArray.new(dt, [3]) { |i| [-7, -1, 7][i] }
      assert_equal([-3, -1, 2], (a / 3).to_a, dt.to_s)
      assert_equal([2, 2, 1],   (a % 3).to_a, dt.to_s)
    end
  end

  def test_unsigned_is_unchanged
    [:uint8, :uint16, :uint32, :uint64].each do |dt|
      a = CArray.new(dt, [3]) { |i| [7, 5, 2][i] }
      assert_equal([2, 1, 0], (a / 3).to_a, dt.to_s)
      assert_equal([1, 2, 2], (a % 3).to_a, dt.to_s)
    end
  end

  def test_float_mod_matches_ruby
    [[-0.4, 1.0], [-1.2, 1.0], [0.6, 1.0], [5.0, 3.0], [0.6, -1.0]].each do |a, b|
      assert_in_delta(a % b, (CA_DOUBLE([a]) % b)[0], 1e-12, "#{a} % #{b}")
    end
  end

  def test_float_div_stays_true_division
    assert_in_delta(-7.0 / 3.0, (CA_DOUBLE([-7.0]) / 3.0)[0], 1e-12)
  end

  def test_object_lane_agrees_with_numeric_lanes
    assert_equal((CA_INT32([-7, -1, 7]) % 3).to_a, (CA_OBJECT([-7, -1, 7]) % 3).to_a)
    assert_equal((CA_INT32([-7, -1, 7]) / 3).to_a, (CA_OBJECT([-7, -1, 7]) / 3).to_a)
  end

  def test_fmod_keeps_the_truncating_form
    assert_equal([-0.4, 0.6], CA_DOUBLE([-0.4, 0.6]).fmod(1.0).to_a.map { |v| v.round(10) })
  end

  def test_fmod_accepts_integers
    assert_equal([-1, -1, 1, 2], CA_INT32([-7, -1, 7, 5]).fmod(3).to_a)
    assert_equal([-1, 1],        CA_INT32([-7, 7]).fmod(-3).to_a)
    assert_equal([1],            CA_UINT8([7]).fmod(3).to_a)
  end

  def test_fmod_matches_ruby_remainder
    SIGN_CASES.each do |a, b|
      assert_equal(a.remainder(b), CA_INT32([a]).fmod(b)[0], "#{a} fmod #{b}")
    end
  end

  # The object lane delegates to Numeric#remainder, so an Integer element
  # comes back an Integer rather than going out through a double.
  def test_fmod_object_lane_keeps_the_element_class
    assert_equal([-1, 1], CA_OBJECT([-7, 7]).fmod(3).to_a)
    assert_equal((CA_INT32([-7, 7]).fmod(3)).to_a, CA_OBJECT([-7, 7]).fmod(3).to_a)
  end

  def test_fmod_by_zero_raises_for_integers
    assert_raise(ZeroDivisionError) { CA_INT32([1]).fmod(0) }
  end

  # A masked zero divisor must not trap: the integer fmod lane traps the
  # same way `%` does, so it has to be classified trapping for the lazy
  # path to skip masked cells.
  def test_masked_zero_divisor_is_skipped
    a = CA_INT32([1, 2])
    b = CA_INT32([0, 3])
    b[0] = UNDEF
    assert_equal([UNDEF, 2], a.fmod(b).to_a)
    assert_equal([UNDEF, 2], (a.lazy.fmod(b)).to_ca.to_a)
    assert_equal([UNDEF, 2], (a.lazy % b).to_ca.to_a)
    assert_equal([UNDEF, 0], (a.lazy / b).to_ca.to_a)
  end

  # A zero remainder takes the divisor's sign, so "the sign follows the
  # divisor" holds without exception.  Ruby leaves fmod's dividend sign
  # here instead; the difference is only in the sign of zero.
  def test_zero_remainder_takes_the_divisor_sign
    assert_equal(Float::INFINITY,  1.0 / (CA_DOUBLE([-4.0]) % 2.0)[0])
    assert_equal(-Float::INFINITY, 1.0 / (CA_DOUBLE([4.0]) % -2.0)[0])
  end

  def test_division_by_zero_still_raises
    assert_raise(ZeroDivisionError) { CA_INT32([1]) / 0 }
    assert_raise(ZeroDivisionError) { CA_INT32([1]) % 0 }
  end

  def test_lazy_matches_eager
    a = CA_INT32([-7, -1, 7])
    assert_equal((a / 3).to_a, (a.lazy / 3).to_ca.to_a)
    assert_equal((a % 3).to_a, (a.lazy % 3).to_ca.to_a)
  end

  def test_array_divisor
    a = CA_INT32([-7, -1, 7])
    b = CA_INT32([3, -3, 3])
    assert_equal([-3, 0, 2], (a / b).to_a)
    assert_equal([2, -1, 1], (a % b).to_a)
  end

  def test_divmod_matches_ruby
    SIGN_CASES.each do |a, b|
      q, r = CA_INT32([a]).divmod(b)
      assert_equal(a.divmod(b), [q[0], r[0]], "#{a}.divmod(#{b})")
    end
  end

  def test_divmod_identity
    a = CA_INT32([-7, -1, 7])
    q, r = a.divmod(3)
    assert_equal(a.to_a, (q * 3 + r).to_a)
  end

  # The quotient keeps the receiver's data type rather than dropping to an
  # Integer the way Ruby's Float#divmod does.
  def test_divmod_floors_the_float_quotient
    q, r = CA_DOUBLE([-7.0]).divmod(3.0)
    assert_equal([-3.0], q.to_a)
    assert_equal([2.0], r.to_a)
  end

  def test_divmod_array_divisor
    q, r = CA_INT32([-7, -1, 7]).divmod(CA_INT32([3, 3, -3]))
    assert_equal([-3, -1, -3], q.to_a)
    assert_equal([2, 2, -2], r.to_a)
  end

  def test_divmod_object_lane
    q, r = CA_OBJECT([Rational(7, 2)]).divmod(3)
    assert_equal(Rational(7, 2).divmod(3), [q[0], r[0]])
  end

  def test_divmod_refuses_complex
    assert_raise(ArgumentError) { CA_CMPLX128([Complex(1, 1)]).divmod(2) }
  end

  def test_bang_forms
    a = CA_INT32([-7, -1, 7])
    assert_equal([-3, -1, 2], a.copy.div!(3).to_a)
    assert_equal([2, 2, 1],   a.copy.mod!(3).to_a)
  end
end
