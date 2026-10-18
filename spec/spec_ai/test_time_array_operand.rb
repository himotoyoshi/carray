# frozen_string_literal: true
#
# A Ruby Array given to a time comparison or to count(v) is a list of values,
# one per cell (or one per query), not a single value.  The comparison gate
# once unwrapped it as a scalar and compared every cell with its first value.

require "test/unit"
require "carray"

class TestTimeArrayOperand < Test::Unit::TestCase

  def days
    CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
  end

  def test_comparison_is_cell_by_cell
    d = days
    assert_equal [true, true, true],    d.eq(d.to_a).to_a
    assert_equal [true, true, true],    d.eq(%w[2024-01-01 2024-01-02 2024-01-03]).to_a
    assert_equal [false, true, true],   (d >= d.to_a.reverse).to_a
    assert_equal [true, false, false],  (d < d.to_a.reverse).to_a
    assert_equal [-1, 0, 1],            (d <=> d.to_a.reverse).to_a
    assert_equal [false, true, false],  d.mask_eq(d.to_a.reverse).is_masked.to_a
  end

  def test_a_scalar_still_compares_with_every_cell
    assert_equal [false, true, false], days.eq("2024-01-02").to_a
    assert_equal 1, days.count("2024-01-02")
  end

  def test_length_mismatch_raises
    assert_raise(ArgumentError) { days.eq(%w[2024-01-01 2024-01-02]) }
  end

  def test_a_nested_array_keeps_its_shape
    d2 = CArray.time([["2024-01-01", "2024-01-02"], ["2024-01-03", "2024-01-04"]], unit: :D)
    assert_equal [[true, true], [true, true]], d2.eq(d2.to_a).to_a
    assert_equal [true, false], days[0..1].is_in([["2024-01-01"]]).to_a
  end

  def test_timedelta
    td = CArray.int64(3) { |i| i + 1 }.timedelta(unit: :h)
    assert_equal [true, false, false], (td < td.to_a.reverse).to_a
    assert_equal [1, 1, 1], td.count(td.to_a).to_a
  end

  def test_count_takes_a_list_of_queries
    d = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03 2024-01-03], unit: :D)
    assert_equal [1, 2], d.count(%w[2024-01-02 2024-01-03]).to_a
  end

end
