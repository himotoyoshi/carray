# spec_ai/test_scalar_view_shape.rb
#
# A view of a scalar is itself a scalar only while it is what a scalar is:
# one cell along one axis.  A selection that picks no cell, or a refer that
# reads the cell under another shape, is an array of that shape, and its
# copy, its arithmetic and its conversions keep the shape.
#
# A CScalar takes no index, so the selections are made on a refer of it,
# which is a scalar that does.

require "test/unit"
require "carray"

class TestScalarViewShape < Test::Unit::TestCase

  def scalar (v = 5.0)
    s = CScalar.new(CA_FLAG_SCALAR_TYPE)
    s[0] = v
    s
  end

  CA_FLAG_SCALAR_TYPE = CA_FLOAT64

  def assert_same_as_entity (view, entity, name)
    assert_equal entity.shape, view.shape, "#{name} shape"
    assert_equal entity.to_a, view.to_a, "#{name} to_a"
    assert_equal entity.to_a, view.copy.to_a, "#{name} copy"
    assert_equal entity.shape, view.copy.shape, "#{name} copy shape"
    assert_equal (entity + 0).to_a, (view + 0).to_a, "#{name} + 0"
    assert_equal entity.to_type(:int32).to_a, view.to_type(:int32).to_a, "#{name} to_type"
    assert_equal (entity.lazy + 1).to_a, (view.lazy + 1).to_a, "#{name} lazy"
  end

  def one_cell_entity
    e = CArray.float64(1)
    e[0] = 5.0
    e
  end

  def test_a_selection_of_no_cell
    s = scalar.refer(CA_FLOAT64, [1])
    e = one_cell_entity
    assert_same_as_entity s[s.gt(10)], e[e.gt(10)], "scalar parent"
    no = CScalar.new(CA_BOOLEAN)
    no[0] = false
    assert_same_as_entity e[no], e[e.gt(10)], "scalar selector"
  end

  def test_a_selection_of_no_cell_of_a_masked_scalar
    s = scalar
    s[0] = UNDEF
    s = s.refer(CA_FLOAT64, [1])
    v = s[s.gt(10)]
    assert_equal 0, v.elements
    assert_equal [], v.copy.to_a
  end

  def test_a_refer_under_another_shape
    s = scalar(1.0)
    e = CArray.float64(1)
    e[0] = 1.0
    assert_same_as_entity s.refer(CA_FLOAT64, [1, 1]), e.refer(CA_FLOAT64, [1, 1]), "refer [1,1]"
  end

  # One cell along one axis is still a scalar.
  def test_one_cell_stays_a_scalar
    s = scalar
    r = s.refer(CA_FLOAT64, [1])
    assert_kind_of CScalar, r[r.gt(0)].copy
    assert_kind_of CScalar, s.refer(CA_FLOAT64, [1]).copy
  end
end
