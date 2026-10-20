require "test/unit"
require "carray"

# A NaN cell stays NaN through clip, one-sided as two-sided.  A one-sided
# clip went through pmax / pmin and answered the bound for it.
class TestClipNanCell < Test::Unit::TestCase

  def test_one_and_two_sided_agree
    a = CA_DOUBLE([Float::NAN, 1, 5])
    assert_equal [true, false, false], a.clip(0, 2).is_nan.to_a
    assert_equal [true, false, false], a.clip(0, nil).is_nan.to_a
    assert_equal [true, false, false], a.clip(nil, 2).is_nan.to_a
    assert_equal [1.0, 5.0], a.clip(0, nil).to_a[1..]
    assert_equal [1.0, 2.0], a.clip(nil, 2).to_a[1..]
    assert_equal [true, false, false], a.clip(0, nil, ufill: 9).is_nan.to_a
    assert_equal [true, false, false], a.lazy.clip(0, nil).to_ca.is_nan.to_a
  end

  def test_pmax_still_answers_the_other_operand
    assert_equal [0.0, 1.0, 5.0], CA_DOUBLE([Float::NAN, 1, 5]).pmax(0).to_a
  end

  def test_integers_unchanged
    assert_equal [2, 5], CA_INT32([1, 5]).clip(2, nil).to_a
    assert_equal [1, 3], CA_INT32([1, 5]).clip(nil, 3).to_a
  end

end
