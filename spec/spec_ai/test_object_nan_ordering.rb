require "test/unit"
require "carray"

# A Float NaN stored in an object array loses every comparison, as it
# does in a float64 array: it never displaces another value, a run of
# nothing but NaN answers NaN, the position of such a run is UNDEF, and a
# sort puts it after every other value.
class TestObjectNanOrdering < Test::Unit::TestCase

  NAN = Float::NAN

  def same (a, b)
    a.is_a?(Float) && a.nan? ? (b.is_a?(Float) && b.nan?) : a == b
  end

  def assert_same_answer (expect, got, msg)
    if expect.is_a?(Array)
      assert_equal expect.size, got.size, msg
      expect.zip(got).each { |e, g| assert same(e, g), "#{msg}: #{expect.inspect} vs #{got.inspect}" }
    else
      assert same(expect, got), "#{msg}: #{expect.inspect} vs #{got.inspect}"
    end
  end

  CASES = [[NAN, 1.0, 2.0], [1.0, NAN, 2.0], [2.0, 1.0, NAN], [NAN, NAN], [NAN, -1.0, NAN, 3.0]]

  CASES.each_with_index do |vals, i|
    define_method("test_flat_matches_float64_#{i}") do
      o = CA_OBJECT(vals)
      f = CA_FLOAT64(vals)
      %i[min max minmax min_index max_index min_addr max_addr].each do |op|
        assert_same_answer f.send(op), o.send(op), "#{op} #{vals.inspect}"
      end
      %i[cummin cummax].each do |op|
        assert_same_answer f.send(op).to_a, o.send(op).to_a, "#{op} #{vals.inspect}"
      end
    end
  end

  def test_along_an_axis
    rows = [[NAN, 3.0, 1.0], [NAN, NAN, NAN], [2.0, NAN, 5.0]]
    o = CA_OBJECT(rows)
    f = CA_FLOAT64(rows)
    %i[min max min_index max_index min_addr max_addr].each do |op|
      assert_same_answer f.send(op, axis: 1).to_a, o.send(op, axis: 1).to_a, "#{op}(axis: 1)"
    end
  end

  CASES.each_with_index do |vals, i|
    define_method("test_sort_family_matches_float64_#{i}") do
      o = CA_OBJECT(vals)
      f = CA_FLOAT64(vals)
      assert_equal f.sort_index.to_a, o.sort_index.to_a, "sort_index #{vals.inspect}"
      assert_equal f.rank_index.to_a, o.rank_index.to_a, "rank_index #{vals.inspect}"
      assert_same_answer f.sort.to_a, o.sort.to_a, "sort #{vals.inspect}"
      kth = vals.size / 2
      assert_same_answer f.partition(kth).to_a[kth], o.partition(kth).to_a[kth], "partition #{vals.inspect}"
    end
  end

  def test_mixed_numeric_objects
    o = CA_OBJECT([2, NAN, 1r])
    assert_equal 1r, o.min
    assert_equal 2, o.max
    assert_equal 2, o.min_index
  end

  def test_pmax_pmin_let_a_nan_lose_and_maximum_minimum_let_it_win
    nan = Float::NAN
    o = CA_OBJECT([nan, 1.0, 3.0])
    f = CA_FLOAT64([nan, 1.0, 3.0])
    assert_equal f.pmax(2.0).to_a, o.pmax(2.0).to_a
    assert_equal f.pmin(2.0).to_a, o.pmin(2.0).to_a
    assert o.maximum(2.0)[0].nan?
    assert o.minimum(2.0)[0].nan?
    assert_equal [2.0, 3.0], o.maximum(2.0).to_a[1..2]
    assert_equal [3, 5], CA_OBJECT([1, 5]).pmax(CA_OBJECT([3, 2])).to_a
  end

  def test_windows_extremum_on_an_object_array_with_nan
    nan = Float::NAN
    assert_equal CA_FLOAT64([1.0, nan, 3.0]).windows(0..1).max.to_a,
                 CA_OBJECT([1.0, nan, 3.0]).windows(0..1).max.to_a
  end

  def test_equality_of_a_nan_does_not_depend_on_the_float_object
    nan = Float::NAN
    other = 0.0 / 0.0
    o = CA_OBJECT([nan, 1.0, other])
    assert_equal 0, o.count(nan)
    assert_nil o.search(other)
    assert_equal 1, o.search(1.0)
    f = CA_FLOAT64([nan, 1.0, nan])
    assert_equal f.rank_index(method: :dense).to_a,
                 CA_OBJECT([nan, 1.0, nan]).rank_index(method: :dense).to_a
    assert_equal CA_OBJECT([nan, 1.0, nan]).rank_index(method: :dense).to_a,
                 CA_OBJECT([nan, 1.0, other]).rank_index(method: :dense).to_a
  end
end
