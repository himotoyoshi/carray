require "test/unit"
require "carray"

# group_by_category(...).<op>(axis: 0) over a 1-D value whose data type
# the fused kernels cannot read: each group reduces to one cell, and the
# answer is a 1-D array of the groups, as it is for a numeric value.

class TestCategoricalAxisOneD < Test::Unit::TestCase

  def cat
    CA_INT32([0, 1, 2, 0, 1, 2]).categorize
  end

  def test_boolean_sum_and_mean
    b = CArray.boolean(6)
    b[] = [1, 0, 1, 1, 0, 0]
    s = b.group_by_category(cat).sum(axis: 0)
    assert_equal :uint64, s.data_type
    assert_equal [2, 0, 1], s.to_a
    assert_equal [1.0, 0.0, 0.5], b.group_by_category(cat).mean(axis: 0).to_a
  end

  def test_object_sum
    o = CA_OBJECT([1, 0, 1, 1, 0, 0])
    assert_equal [2, 0, 1], o.group_by_category(cat).sum(axis: 0).to_a
  end

  def test_complex_mean
    c = CA_CMPLX128([1, 0, 1, 1, 0, 0])
    assert_equal [Complex(1.0), Complex(0.0), Complex(0.5)],
                 c.group_by_category(cat).mean(axis: 0).to_a
  end

  def test_time_min_keeps_the_face
    t = CArray.time(%w[2020-01-01 2020-01-02 2020-01-03 2020-01-04 2020-01-05 2020-01-06])
    m = t.group_by_category(cat).min(axis: 0)
    assert_kind_of CATime, m
    assert_equal %w[2020-01-01 2020-01-02 2020-01-03], m.to_a.map(&:to_s)
  end

  def test_same_shape_as_the_numeric_value
    x = CA_INT32([1, 0, 1, 1, 0, 0])
    b = CArray.boolean(6)
    b[] = [1, 0, 1, 1, 0, 0]
    assert_equal x.group_by_category(cat).sum(axis: 0).shape,
                 b.group_by_category(cat).sum(axis: 0).shape
  end

end
