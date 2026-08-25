# Test for CArray#is_in (value-hash discovery family, 2-array membership member).
#
# Contract (PROPOSAL_ISIN_SET_OPS):
#   - Returns a boolean CArray of self.shape, true where self's value is in the
#     set `values` (any shape / Array / Range, flattened to one seen-set).
#   - Single argument; a few immediate values are passed as an Array.
#   - Value-based distinctness shared with the discovery family: numeric `==`
#     with all NaN collapsed and -0.0 == +0.0; CA_OBJECT hash/eql? with Float
#     NaN collapsed; CA_FIXLEN byte equality.
#   - Masked cells of `values` do not enter the set; masked cells of self stay
#     masked in the result (mask propagation, like a comparison).
#   - Empty set yields all false.
#
# Boolean results are compared as 0/1 integer arrays (CArray boolean bulk
# conversion emits Integer 0/1).

require "test/unit"
require "carray"

class TestIsIn < Test::Unit::TestCase

  def test_integer_membership
    a = CA_INT32([1, 2, 3, 4, 5])
    assert_equal [false, true, false, true, false], a.is_in([2, 4, 6]).to_a
    assert_equal CA_BOOLEAN, a.is_in([2]).data_type
  end

  def test_shape_preserved
    m = CA_INT32([[1, 2], [3, 4]])
    assert_equal [[true, false], [false, true]], m.is_in([1, 4]).to_a
    assert_equal m.dim, m.is_in([1]).dim
  end

  def test_carray_set_argument
    s1 = CA_INT32([10, 20, 30, 40])
    s2 = CA_INT32([20, 40, 50])
    assert_equal [false, true, false, true], s1.is_in(s2).to_a
  end

  def test_cross_dtype_numeric_coercion
    f = CA_DOUBLE([1.0, 2.0, 3.0])
    assert_equal [false, true, true], f.is_in([2, 3]).to_a
  end

  def test_range_argument
    a = CA_INT32([1, 2, 3, 4, 5])
    assert_equal [true, true, true, false, false], a.is_in(1..3).to_a
  end

  def test_empty_set_all_false
    assert_equal [false, false, false], CA_INT32([1, 2, 3]).is_in([]).to_a
  end

  def test_nan_collapses_and_matches
    # is_in([NaN]) marks NaN cells true (value-based NaN collapse), unlike the
    # retired contains (self.eq(NaN)) which returned false at NaN cells.
    g = CA_DOUBLE([1.0, Float::NAN, 3.0])
    assert_equal [false, true, false], g.is_in([Float::NAN]).to_a
  end

  def test_negative_zero_equals_positive_zero
    z = CA_DOUBLE([-0.0, 0.0, 1.0])
    assert_equal [true, true, false], z.is_in([0.0]).to_a
    assert_equal [true, true, false], z.is_in([-0.0]).to_a
  end

  def test_object_lane
    o = CArray.object(3) { |i| ["a", "b", "c"][i] }
    assert_equal [false, true, true], o.is_in(["b", "c"]).to_a
  end

  def test_fixlen_lane
    a = CArray.new(CA_FIXLEN, [4], bytes: 3)
    a[0] = "foo"; a[1] = "bar"; a[2] = "baz"; a[3] = "qux"
    set = CArray.new(CA_FIXLEN, [2], bytes: 3)
    set[0] = "bar"; set[1] = "qux"
    assert_equal [false, true, false, true], a.is_in(set).to_a
  end

  def test_masked_self_cell_stays_masked
    a = CA_INT32([1, 2, 3, 4])
    a[1] = UNDEF
    r = a.is_in([2, 3, 4])
    assert_equal [false, true, false, false], r.is_masked.to_a   # masked where self masked
    assert_equal false, r.value[1]                    # payload false under the mask
  end

  def test_masked_values_cell_excluded_from_set
    v = CA_INT32([2, 3])
    v[0] = UNDEF                      # set = {3}
    assert_equal [false, false, true], CA_INT32([1, 2, 3]).is_in(v).to_a
  end

  def test_view_receiver
    big = CA_INT32([[1, 2, 3], [4, 5, 6]])
    assert_equal [true, false, true], big[1, nil].is_in([4, 6]).to_a
  end

  def test_any_axis_composition
    # per-fiber "contains any of" = is_in(...).any(axis: k)
    m = CA_INT32([[1, 2, 3], [4, 5, 6]])
    assert_equal [true, false], m.is_in([1, 2]).any(axis: 1).to_a
  end

  # ---- set relations: intersection / difference / union --------------------

  def test_intersection_basic
    a = CA_INT32([1, 2, 3, 4, 5, 3, 2])
    b = CA_INT32([3, 4, 4, 6, 7])
    r = a.intersection(b)
    assert_equal [3, 4], r.to_a          # distinct in both, self order
    assert_equal CA_INT32, r.data_type
    assert_equal 1, r.ndim
  end

  def test_difference_basic
    a = CA_INT32([1, 2, 3, 4, 5, 3, 2])
    b = CA_INT32([3, 4, 4, 6, 7])
    assert_equal [1, 2, 5], a.difference(b).to_a
  end

  def test_union_basic
    a = CA_INT32([1, 2, 3, 4, 5, 3, 2])
    b = CA_INT32([3, 4, 4, 6, 7])
    assert_equal [1, 2, 3, 4, 5, 6, 7], a.union(b).to_a
  end

  def test_union_appearance_order_self_then_other
    a = CA_INT32([5, 1, 5])
    b = CA_INT32([9, 1, 3])
    assert_equal [5, 1, 9, 3], a.union(b).to_a
  end

  def test_datetime_axis_overlap_and_merge
    # int64 time axes (CATime storage): common / dropped / merged axis.
    t1 = CA_INT64([10, 20, 30, 40])
    t2 = CA_INT64([20, 40, 50, 60])
    assert_equal [20, 40], t1.intersection(t2).to_a
    assert_equal [10, 30], t1.difference(t2).to_a
    assert_equal [10, 20, 30, 40, 50, 60], t1.union(t2).to_a
  end

  def test_set_ops_nan_collapse
    f = CA_DOUBLE([1.0, Float::NAN, 2.0])
    g = CA_DOUBLE([Float::NAN, 2.0, 3.0])
    inter = f.intersection(g).to_a
    assert_equal 2, inter.size
    assert inter[0].nan?                  # NaN counted as common
    assert_equal 2.0, inter[1]
    # difference: 1.0 only (NaN and 2.0 are in g)
    assert_equal [1.0], f.difference(g).to_a
  end

  def test_set_ops_object_lane
    o1 = CArray.object(3) { |i| %w[a b c][i] }
    o2 = CArray.object(2) { |i| %w[b d][i] }
    assert_equal ["b"], o1.intersection(o2).to_a
    assert_equal ["a", "c"], o1.difference(o2).to_a
    assert_equal ["a", "b", "c", "d"], o1.union(o2).to_a
  end

  def test_set_ops_fixlen_lane
    a = CArray.new(CA_FIXLEN, [3], bytes: 3)
    a[0] = "foo"; a[1] = "bar"; a[2] = "baz"
    b = CArray.new(CA_FIXLEN, [2], bytes: 3)
    b[0] = "bar"; b[1] = "qux"
    strip = ->(ca) { ca.to_a.map { |s| s.delete("\x00") } }
    assert_equal ["bar"], strip[a.intersection(b)]
    assert_equal ["foo", "baz"], strip[a.difference(b)]
    assert_equal ["foo", "bar", "baz", "qux"], strip[a.union(b)]
  end

  def test_set_ops_masked_cells_excluded
    a = CA_INT32([1, 2, 3, 4])
    a[1] = UNDEF                          # self set = {1,3,4}
    b = CA_INT32([2, 3])
    b[0] = UNDEF                          # other set = {3}
    assert_equal [3], a.intersection(b).to_a
    assert_equal [1, 4], a.difference(b).to_a
    assert_equal [1, 3, 4], a.union(b).to_a
  end

  def test_set_ops_empty_result
    a = CA_INT32([1, 2, 3])
    b = CA_INT32([4, 5, 6])
    assert_equal [], a.intersection(b).to_a
    assert_equal 0, a.intersection(b).elements
  end

  def test_set_ops_coerce_and_range_and_view
    a = CA_INT32([[1, 2, 3], [4, 5, 6]])
    assert_equal [2, 3], a[0, nil].intersection([2, 3, 9]).to_a   # view + Array
    assert_equal [1, 2], a[0, nil].intersection(1..2).to_a        # Range
    f = CA_DOUBLE([1.0, 2.0, 3.0])
    assert_equal [2.0, 3.0], f.intersection([2, 3, 9]).to_a       # dtype coerce
  end

  def test_multidim_flattens
    a = CA_INT32([[1, 2], [3, 1]])
    b = CA_INT32([[2, 3], [3, 9]])
    assert_equal [2, 3], a.intersection(b).to_a
    assert_equal [1], a.difference(b).to_a
  end

  def test_cross_dtype_promotes_no_truncation
    # int32 vs float64: promote to float64 (CArray.result_type), so a
    # fractional set element never truncates onto an int cell.
    si = CA_INT32([1, 2, 3])
    of = CA_DOUBLE([2.5, 3.0, 4.0])
    assert_equal [1.0, 2.0, 3.0, 2.5, 4.0], si.union(of).to_a
    assert_equal [3.0], si.intersection(of).to_a        # 2.5 does NOT match 2
    assert_equal [false, false, true], si.is_in(of).to_a           # 2 is not in {2.5,3.0,4.0}
    assert_equal CA_DOUBLE, si.union(of).data_type
  end

  def test_bare_array_literal_promotes_like_carray
    # a fractional literal against an int self promotes (no truncation),
    # matching the behaviour of a float CArray argument.
    assert_equal [1.0, 2.0, 3.0, 2.5], CA_INT32([1, 2, 3]).union([2.5]).to_a
    assert_equal [false, false, false], CA_INT32([1, 2, 3]).is_in([2.5]).to_a
  end

  def test_object_union_with_array
    o = CArray.object(3) { |i| %w[a b c][i] }
    assert_equal ["a", "b", "c", "d"], o.union(["c", "d"]).to_a
  end

  def test_is_in_shape_not_broadcast_by_promotion
    # promotion must reconcile dtype only, never couple shapes: a size-1
    # self against a larger set keeps self's shape.
    assert_equal [[true]], CA_INT32([[7]]).is_in([7, 8, 9]).to_a
  end

  def test_incompatible_dtype_raises
    assert_raise(RuntimeError) do
      CA_INT32([1]).union(CArray.new(CA_FIXLEN, [1], bytes: 3))
    end
  end

  def test_sort_option
    a = CA_INT32([5, 1, 3])
    assert_equal [5, 1, 3, 9, 2], a.union([9, 2]).to_a               # appearance
    assert_equal [1, 2, 3, 5, 9], a.union([9, 2], sort: true).to_a   # ascending
    assert_equal [3, 5], a.intersection([3, 5, 9], sort: true).to_a
    assert_equal [1, 5], a.difference([3], sort: true).to_a
  end

  def test_contains_retired
    # contains was retired in favour of is_in (value-hash membership).
    # Migration: a.contains(v1, v2) -> a.is_in([v1, v2]).
    assert_equal false, CA_INT32([1, 2, 3]).respond_to?(:contains)
  end

end
