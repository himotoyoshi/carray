require "test/unit"
require "carray"

# scatter_replace! is an assignment, so it takes an object or fixlen array
# as put_nd and put_along_axis do; it refused them, while the reading side
# (project, gather_nd, x[i]) took them.
class TestScatterReplaceObject < Test::Unit::TestCase

  def test_object
    o = CA_OBJECT([1, 2, 3])
    o.scatter_replace!(CA_INT64([0, 2]), CA_OBJECT(["x", "y"]))
    assert_equal ["x", 2, "y"], o.to_a
    o.scatter_replace!([1, 1], CA_OBJECT(["a", "b"]))
    assert_equal ["x", "b", "y"], o.to_a
    o.scatter_replace!(CA_INT64([0]), :z)
    assert_equal [:z, "b", "y"], o.to_a
  end

  def test_masks_and_shape
    o = CA_OBJECT([1, 2, 3])
    a = CA_INT64([0, 2]); a[1] = UNDEF
    o.scatter_replace!(a, CA_OBJECT([7, 8]))
    assert_equal [7, 2, 3], o.to_a
    v = CA_OBJECT([7, 8]); v[0] = UNDEF
    o.scatter_replace!(CA_INT64([0, 1]), v)
    assert_equal [UNDEF, 8, 3], o.to_a
    m = CArray.object(2, 2) { 0 }
    m.scatter_replace!(CA_INT64([3]), :q)
    assert_equal [[0, 0], [0, :q]], m.to_a
    assert_raise(IndexError) { CA_OBJECT([1]).scatter_replace!(CA_INT64([5]), 1) }
  end

  def test_fixlen
    f = CArray.fixlen_string(%w[ab cd])
    f.scatter_replace!(CA_INT64([1]), "zz")
    assert_equal ["ab", "zz"], f.to_a
  end

  def test_accumulate_still_numeric_only
    assert_raise(CArray::DataTypeError) { CA_OBJECT([1]).scatter_add!(CA_INT64([0]), 1) }
  end

end
