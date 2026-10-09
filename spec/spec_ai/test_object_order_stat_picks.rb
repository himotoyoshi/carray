require "test/unit"
require "carray"

# Order statistics on an object array: picking an element (an odd-length
# median, method: :lower / :higher / :nearest) needs only an ordering, a
# number is reported as a Float, interpolation is refused for any fiber
# that holds a non-number, and the result is an object array on every path.

class TestObjectOrderStatPicks < Test::Unit::TestCase

  def test_picking_needs_only_an_ordering
    a = CA_OBJECT([:b, :a, :c])
    assert_equal :b, a.median
    [:lower, :higher, :nearest].each do |m|
      assert_equal :b, a.percentile(50, method: m), m.to_s
    end
    assert_equal :b, CA_OBJECT([:b, :a, :c, :d]).percentile(30, method: :nearest)
    assert_raise(CArray::DataTypeError) { CA_OBJECT([:b, :a, :c, :d]).median }
  end

  def test_numbers_are_reported_as_floats
    assert_equal 2.0, CA_OBJECT([3, 1, 2]).median
    assert_kind_of Float, CA_OBJECT([3, 1, 2]).percentile(50, method: :lower)
  end

  def test_interpolation_checks_every_fiber
    a = CA_OBJECT([[1, 2, 3, 4], ["a", "b", "c", "d"]])
    assert_raise(CArray::DataTypeError) { a.percentile(50, axis: 1) }
    b = CA_OBJECT([["a", "b", "c", "d"], [1, 2, 3, 4]])
    assert_raise(CArray::DataTypeError) { b.percentile(50, axis: 1) }
    assert_equal [2.0, "b"], a.percentile(50, axis: 1, method: :lower).to_a
  end

  def test_result_is_an_object_array_on_every_path
    assert_equal "object", CArray.object(0, 3).median(axis: 0).data_type_name
    assert_equal "object", CArray.object(3, 0).median(axis: 1).data_type_name
    assert_equal "object", CArray.object(0, 3).percentile(50, axis: 0, keep_axis: true).data_type_name
    o = CA_OBJECT([Rational(1, 3), Rational(1, 2), 5, 7]).reshape(4, 1)
    g = o[o.axis_group(CA_INT32([0, 0, 1, 1]).categorize, nil)]
    assert_equal "object", g.median(axis: :group).data_type_name
  end

end
