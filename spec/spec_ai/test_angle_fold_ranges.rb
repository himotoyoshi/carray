require "test/unit"
require "carray"

class TestAngleFoldRanges < Test::Unit::TestCase

  TWO_PI = 2 * Math::PI

  def test_a_negative_multiple_folds_to_zero
    assert_equal [0.0, 0.0, 0.0, 0.0, 0.0], CA_FLOAT64([-360.0, -720.0, 360.0, 0.0, -1080.0]).deg_360.to_a
    assert_equal [0.0, 0.0], CA_FLOAT64([-TWO_PI, -2 * TWO_PI]).rad_2pi.to_a
  end

  def test_the_fold_stays_below_the_top_in_each_width
    v = [-1e-20, -1e-9, -1e-6, -359.99999, 359.99999, 1e-20]
    %i[float64 float32].each { |t|
      a = CArray.new(t, [v.size])
      v.each_with_index { |x, i| a[i] = x }
      assert_true a.deg_360.lt(360.0).all, "deg_360 #{t}"
      assert_true a.rad_2pi.lt(TWO_PI).all, "rad_2pi #{t}"
      assert_true a.deg_360.ge(0.0).all, "deg_360 #{t}"
    }
  end

  def test_ordinary_values_are_unchanged
    [[-10.0, 350.0], [370.0, 10.0], [90.0, 90.0]].each { |v, want|
      assert_in_delta want, CA_FLOAT64([v]).deg_360[0], 1e-12
    }
    assert_in_delta TWO_PI - 1.0, CA_FLOAT64([-1.0]).rad_2pi[0], 1e-12
  end

  def test_object_cells_follow_the_same_rule
    assert_equal [0.0, 350.0], CA_OBJECT([-360, -10.0]).deg_360.to_a
    assert_equal 0.0, CA_OBJECT([-TWO_PI]).rad_2pi[0]
  end
end
