# frozen_string_literal: true
#
# What CArray.time and #time / #timedelta take as a count of ticks: an
# Integer among values that make the chosen unit finer is still seconds, and
# a uint64 count that int64 cannot hold raises.

require "test/unit"
require "carray"

class TestTimeInputStorage < Test::Unit::TestCase

  def strs(t) = t.to_a.map(&:to_s)

  def test_integer_among_finer_values_is_seconds
    assert_equal %w[2023-11-14T22:13:20.000Z 2024-01-01T00:00:00.500Z],
                 strs(CArray.time([1700000000, "2024-01-01T00:00:00.5"]))
    assert_equal %w[2023-11-14T22:13:20.000Z 2024-01-01T00:00:00.500Z],
                 strs(CArray.time(CA_OBJECT([1700000000, "2024-01-01T00:00:00.5"])))
    assert_equal ["2023-11-14T22:13:20.000Z", "1970-01-01T00:00:00.005Z"],
                 strs(CArray.time([1700000000, Time.at(0, 5, :millisecond).utc]))
  end

  def test_integer_with_a_unit_counts_its_ticks
    assert_equal %w[1970-01-01T00:05:00Z 1970-01-01T00:00:00Z],
                 strs(CArray.time([5, "1970-01-01"], unit: :m))
  end

  def test_uint64_that_does_not_fit_raises
    big = CA_UINT64([2**63 + 5])
    assert_raise(RangeError) { CArray.time(big, unit: :s) }
    assert_raise(RangeError) { big.time(unit: :s) }
    assert_raise(RangeError) { big.timedelta(unit: :s) }
    assert_equal ["1970-01-01T00:00:03Z"], strs(CA_UINT64([3]).time(unit: :s))
  end

  def test_integer_input_is_copied
    a = CA_INT64([1])
    t = CArray.time(a)
    a[0] = 5
    assert_equal 1, t[0].value
  end

end
