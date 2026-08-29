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

  def test_bang_forms
    a = CA_INT32([-7, -1, 7])
    assert_equal([-3, -1, 2], a.copy.div!(3).to_a)
    assert_equal([2, 2, 1],   a.copy.mod!(3).to_a)
  end
end
