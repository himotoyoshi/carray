require "test/unit"
require "carray"

# CArray#is_between: both bounds included unless exclude: names the one to
# leave out; a Range says the same, its excluded end as exclude: :upper.
class TestIsBetween < Test::Unit::TestCase
  def setup
    @a = CA_FLOAT64([1.5, 2.0, 2.5, 4.0, 4.5, Float::NAN])
    @a[4] = UNDEF
  end

  def test_the_bounds_and_exclude
    assert_equal [false, true, true, true, UNDEF, false], @a.is_between(2, 4).to_a
    assert_equal [false, true, true, false, UNDEF, false], @a.is_between(2, 4, exclude: :upper).to_a
    assert_equal [false, false, true, true, UNDEF, false], @a.is_between(2, 4, exclude: :lower).to_a
    assert_equal [false, false, true, false, UNDEF, false], @a.is_between(2, 4, exclude: :both).to_a
    assert_equal [false] * 4, CA_FLOAT64([1, 2, 3, 4]).is_between(4, 2).to_a
  end

  def test_a_range_and_an_open_side
    assert_equal @a.is_between(2, 4).to_a, @a.is_between(2..4).to_a
    assert_equal @a.is_between(2, 4, exclude: :upper).to_a, @a.is_between(2...4).to_a
    assert_equal [true, true, false, false, UNDEF, false], @a.is_between(..2).to_a
    assert_equal @a.is_between(..2).to_a, @a.is_between(nil, 2).to_a
    assert_equal [false, false, true, true, UNDEF, false], @a.is_between(2.5..).to_a
  end

  # The bounds are what a comparison takes, so a time array is bounded by text.
  def test_a_time_array
    t = CArray.time(%w[2024-01-01 2024-01-15 2024-02-01], unit: :D)
    assert_equal [true, true, false], t.is_between("2024-01-01", "2024-01-31").to_a
    assert_equal [false, true, true], t.is_between(Time.utc(2024, 1, 10)..).to_a
  end

  def test_refusals
    assert_raise(ArgumentError) { @a.is_between(2) }
    assert_raise(ArgumentError) { @a.is_between(2, 4, 5) }
    assert_raise(ArgumentError) { @a.is_between(2..4, exclude: :upper) }
    assert_raise(ArgumentError) { @a.is_between(nil, nil) }
    err = assert_raise(ArgumentError) { @a.is_between(2, 4, exclude: :right) }
    assert_equal "is_between: exclude: must be :lower, :upper or :both (got :right)", err.message
  end
end
