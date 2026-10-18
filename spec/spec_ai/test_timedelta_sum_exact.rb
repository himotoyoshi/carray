require "test/unit"
require "carray"

# A sum of durations is an exact quantity: it is the int64 sum of the
# storage when that fits int64, and RangeError when it does not.  The same
# holds for each cell of a running sum.
class TestTimedeltaSumExact < Test::Unit::TestCase

  DAY_NS = 86400 * 10**9

  def ns (values, *shape)
    a = CArray.int64(values.size).seq
    values.each_with_index { |v, i| a[i] = v }
    a = a.reshape(*shape) unless shape.empty?
    a.timedelta(unit: :ns)
  end

  def test_a_sum_past_2_53_is_exact
    x = ns([200 * DAY_NS, 1, 1])
    assert_equal 200 * DAY_NS + 2, x.sum.value
    assert_equal :ns, x.sum.unit.base
  end

  def test_a_sum_past_2_53_is_exact_along_an_axis
    x = ns([200 * DAY_NS, 1, 1, 300 * DAY_NS, 3, 5], 2, 3)
    assert_equal [200 * DAY_NS + 2, 300 * DAY_NS + 8], x.sum(axis: 1).to_a.map(&:value)
    assert_kind_of CATimedelta, x.sum(axis: 1)
  end

  def test_a_sum_past_int64_raises
    big = 1000 * DAY_NS
    x = ns(Array.new(20000, big))
    assert_raise(RangeError) { x.sum }
    y = ns(Array.new(20000, big) + Array.new(20000, 1), 2, 20000)
    assert_raise(RangeError) { y.sum(axis: 1) }          # one cell past int64
    assert_raise(RangeError) { ns(Array.new(20000, -big)).sum }
  end

  def test_a_sum_that_passes_int64_on_the_way_but_fits_is_exact
    big = 2**62
    x = ns([big, big, big, -big, -big, -big, 7])         # partial sums reach 3 * 2**62
    assert_equal 7, x.sum.value
    y = ns([big, big, -big, 3, big, -big, -big, 4], 2, 4)
    assert_equal [big + 3, -big + 4], y.sum(axis: 1).to_a.map(&:value)
  end

  def test_mask_min_count_and_fill_value_answer_as_before
    x = ns([1, 2, 3, 4], 2, 2)
    x[0, 0] = UNDEF
    assert_equal 9, x.sum.value
    assert_equal [2, 7], x.sum(axis: 1).to_a.map(&:value)
    assert_equal UNDEF, x.sum(min_count: 4)
    r = x.sum(axis: 1, min_count: 2)
    assert_equal [true, false], r.is_masked.to_a
    x[0, 1] = UNDEF
    assert_equal [0, 7], x.sum(axis: 1).to_a.map(&:value)
    assert_equal [5, 7], x.sum(axis: 1, min_count: 1, fill_value: CATimedelta::Element.new(5, :ns)).to_a.map(&:value)
    k = x.sum(axis: 1, keep_axis: true)
    assert_equal [2, 1], k.shape
  end

  def test_an_empty_or_all_masked_sum_is_zero
    assert_equal 0, CArray.int64(0).timedelta(unit: :s).sum.value
    a = CArray.int64(2) { 1 }.timedelta(unit: :s)
    a[0] = UNDEF
    a[1] = UNDEF
    assert_equal 0, a.sum.value
  end


  def test_a_running_sum_past_2_53_is_exact
    x = ns([200 * DAY_NS, 1, 1])
    assert_equal [200 * DAY_NS, 200 * DAY_NS + 1, 200 * DAY_NS + 2], x.cumsum.to_a.map(&:value)
    assert_kind_of CATimedelta, x.cumsum
    y = ns([200 * DAY_NS, 1, 300 * DAY_NS, 3], 2, 2)
    assert_equal [[200 * DAY_NS, 200 * DAY_NS + 1], [300 * DAY_NS, 300 * DAY_NS + 3]],
                 y.cumsum(axis: 1).to_a.map { |r| r.map(&:value) }
  end

  def test_a_running_sum_past_int64_raises
    big = 2**62
    assert_raise(RangeError) { ns([big, big, -big, -big]).cumsum }   # the second cell is 2**63
    assert_raise(RangeError) { ns([1, 2, big, big], 2, 2).cumsum(axis: 1) }
    assert_equal [big, 0, big], ns([big, -big, big]).cumsum.to_a.map(&:value)
  end

  def test_a_running_sum_keeps_the_mask_rule
    x = ns([1, 2, 3])
    x[1] = UNDEF
    assert_equal [1, 1, 4], x.cumsum.to_a.map { |e| e.equal?(UNDEF) ? UNDEF : e.value }
  end

end
