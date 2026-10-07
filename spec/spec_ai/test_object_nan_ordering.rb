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
end
