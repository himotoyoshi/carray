require "test/unit"
require "carray"

# A duration has a running sum, which is a duration; an instant has none,
# and neither has a product.
class TestTimeRunningSum < Test::Unit::TestCase

  def test_timedelta_running_sum
    td = CArray.int64(2, 3) { |i, j| i * 3 + j + 1 }.time(unit: :s) -
         CArray.int64(2, 3) { 0 }.time(unit: :s)
    td[0, 1] = UNDEF
    r = td.cumsum
    assert_kind_of CATimedelta, r
    assert_equal [1, 1, 4, 8, 13, 19], r.ticks.to_a
    assert_equal [[1, 0, 3], [5, 5, 9]], td.cumsum(axis: 0).ticks.to_a
    assert_equal 19, td.accumulate.to_seconds.to_i
    assert_raise(TypeError) { td.prod }
    assert_raise(TypeError) { td.cumprod }
  end

  def test_time_has_no_running_sum
    t = CArray.int64(3) { |i| i }.time(unit: :s)
    %i[cumsum accumulate prod cumprod].each do |op|
      assert_raise(TypeError, op.to_s) { t.send(op) }
    end
  end
end
