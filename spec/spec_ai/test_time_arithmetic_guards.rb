# frozen_string_literal: true
#
# Time arithmetic that has no answer on the storage grid raises instead of
# moving the result: a duration coarser than the grid that is not a whole
# number of its ticks, a sum or difference that leaves int64, and an origin
# between two ticks.

require "test/unit"
require "carray"

class TestTimeArithmeticGuards < Test::Unit::TestCase

  def td(n, unit) = CA_INT64([n]).timedelta(unit: unit)

  def test_a_coarser_duration_has_to_land_on_the_grid
    t7 = CArray.time(["1970-01-01T00"], unit: "7 hours")
    assert_raise(ArgumentError) { t7 + "1 day" }
    assert_raise(ArgumentError) { t7 - td(1, :D) }
    assert_raise(ArgumentError) { t7[0] + td(1, :D)[0] }
    assert_raise(ArgumentError) { td(1, :D) + t7 }
    assert_equal ["1970-01-08T00:00:00Z"], (t7 + "7 days").to_a.map(&:to_s)
    t10 = CArray.time(["2024-01-02T00:10"], unit: "10 minutes")
    assert_raise(ArgumentError) { t10 + td(1, "15 minutes") }
    assert_equal ["2024-01-02T00:40:00Z"], (t10 + td(2, "15 minutes")).to_a.map(&:to_s)
  end

  def test_a_finer_duration_is_still_truncated
    d = CArray.time(["2024-01-02"], unit: :D)
    assert_equal ["2024-01-03"], (d + td(30, :h)).to_a.map(&:to_s)
    assert_equal ["2024-01-02"], (d - td(5, :h)).to_a.map(&:to_s)
    t7 = CArray.time(["1970-01-01T00"], unit: "7 hours")
    assert_equal ["1970-01-01T00:00:00Z"], (t7 + "5 hours").to_a.map(&:to_s)
  end

  def test_overflow_raises
    a = CArray.time(["2200-01-01"], unit: :ns)
    b = CArray.time(["1700-01-01"], unit: :ns)
    assert_raise(RangeError) { a - b }
    assert_raise(RangeError) { a[0] - b[0] }
    c = CArray.time(["2100-01-01"], unit: :ns)
    assert_raise(RangeError) { c + td(73000, :D) }
    assert_raise(RangeError) { c[0] + td(73000, :D)[0] }
    big = td(9 * 10**18, :ns)
    assert_raise(RangeError) { big + big }
    assert_raise(RangeError) { big - (-big) }
    assert_raise(RangeError) { big * 2 }
    assert_raise(RangeError) { big[0] + big[0] }
    assert_raise(RangeError) { big[0] * 2 }
  end

  def test_masked_cells_are_left_out_of_the_overflow_check
    m = CArray.time(["2024-01-02", "2024-01-03"], unit: :D)
    m[1] = UNDEF
    assert_equal ["2024-01-03", "UNDEF"], (m + "1 day").to_a.map(&:to_s)
  end

  def test_origin_has_to_be_on_the_grid
    idx = CA_INT64([0, 1])
    assert_raise(ArgumentError) { idx.time(unit: "3 hours", origin: "2022-01-01T10:00") }
    assert_raise(ArgumentError) { idx.time(unit: :D, origin: "2024-01-01T12:00") }
    assert_raise(ArgumentError) { idx.time(unit: :M, origin: "2024-03-15") }
    assert_equal %w[2022-01-01T09:00:00Z 2022-01-01T12:00:00Z],
                 idx.time(unit: "3 hours", origin: "2022-01-01T09:00").to_a.map(&:to_s)
    assert_equal %w[2024-03 2024-04], idx.time(unit: :M, origin: "2024-03-01").to_a.map(&:to_s)
    assert_equal ["2023-11-14T22:13:20Z"],
                 CA_INT64([0]).time(unit: :s, origin: 1700000000).to_a.map(&:to_s)
  end

end
