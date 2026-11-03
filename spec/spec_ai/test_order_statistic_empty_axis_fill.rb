require "test/unit"
require "carray"

class TestOrderStatisticEmptyAxisFill < Test::Unit::TestCase

  # --- fill_value: over an axis of no length ---------------------------------

  def test_median_of_an_axis_of_no_length_takes_fill_value
    a = CArray.float64(2, 0)
    assert_equal [9.0, 9.0], a.median(axis: 1, fill_value: 9).to_a
    assert_equal [UNDEF, UNDEF], a.median(axis: 1).to_a
  end

  def test_percentile_of_an_axis_of_no_length_takes_fill_value
    a = CArray.float64(2, 0)
    assert_equal [9.0, 9.0], a.percentile(30, axis: 1, fill_value: 9).to_a
    assert_equal [UNDEF, UNDEF], a.percentile(30, axis: 1).to_a
  end

  def test_it_answers_as_a_fully_masked_axis_does
    masked = CArray.float64(2, 3)
    masked[] = UNDEF
    assert_equal masked.median(axis: 1, fill_value: 9).to_a,
                 CArray.float64(2, 0).median(axis: 1, fill_value: 9).to_a
  end

  def test_object_values_over_an_axis_of_no_length
    a = CArray.object(2, 0)
    assert_equal [9, 9], a.median(axis: 1, fill_value: 9).to_a
  end
end
