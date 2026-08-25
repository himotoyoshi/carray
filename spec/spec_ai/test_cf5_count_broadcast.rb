# CF.5: count(v) (β) broadcast when v is a CArray.
#
# PROPOSAL_COUNT_FAMILY.md rev3 Q2 confirmed: v.shape appends to the
# trailing axes of the output (same rule as SEARCH_AXIS / LINEAR_INTERP).
# Each v[k] is counted independently and stacked.
#
# Pinned:
#   - 1-D v: output shape = base_reduced + v.shape
#   - N-D v: arbitrary trailing append
#   - per-axis: base_reduced computed from self.shape minus axes
#   - min_count / fill_value forwarded to each recursive call
#   - bool self + CArray v rejected (TypeError, Q3 extension)
#   - mask propagation through recursive call

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCF5CountBroadcast < Test::Unit::TestCase

  # ---- shape: 1-D v ---------------------------------------------------

  def test_1d_v_full_reduction
    a = CArray.int32(10).seq
    v = CArray.int32(3); v[0]=2; v[1]=5; v[2]=8
    r = a.count(v)
    assert_equal([3],         r.shape)
    assert_equal([1, 1, 1],   r.to_a)
  end

  def test_1d_v_per_axis_reduce
    b = CArray.int32(3, 4).seq.mod(3)
    # b = [[0,1,2,0],[1,2,0,1],[2,0,1,2]]
    v = CArray.int32(3); v[0]=0; v[1]=1; v[2]=2
    r = b.count(v, axis: 0)   # axis 0 reduce, base [4] + v.shape [3]
    assert_equal([4, 3], r.shape)
    # column k counts of {0,1,2}
    expected = [
      [1, 1, 1],   # col 0 = [0,1,2]
      [1, 1, 1],   # col 1 = [1,2,0]
      [1, 1, 1],   # col 2 = [2,0,1]
      [1, 1, 1],   # col 3 = [0,1,2]
    ]
    assert_equal(expected, r.to_a)
  end

  # ---- shape: N-D v ---------------------------------------------------

  def test_2d_v_full_reduction
    a = CArray.int32(10).seq
    v = CArray.int32(2, 3).seq   # v = [[0,1,2],[3,4,5]]
    r = a.count(v)
    assert_equal([2, 3], r.shape)
    # a = [0..9], every v[i,j] in 0..5 -> count = 1 each
    assert_equal([[1, 1, 1], [1, 1, 1]], r.to_a)
  end

  def test_2d_v_per_axis
    a = CArray.int32(2, 5).seq   # [[0..4],[5..9]]
    v = CArray.int32(2, 2).seq   # [[0,1],[2,3]]
    r = a.count(v, axis: 0)   # axis 0 reduce, base [5] + v.shape [2,2]
    assert_equal([5, 2, 2], r.shape)
  end

  # ---- options forwarding (min_count / fill_value) --------------------

  def test_min_count_forwarded_through_broadcast
    a = CArray.int32(10).seq
    a[3] = UNDEF
    v = CArray.int32(3); v[0]=3; v[1]=4; v[2]=5
    # 9 valid >= 9 -> OK
    assert_equal([0, 1, 1], a.count(v, min_count: 9).to_a)
    # 9 valid < 10 -> all UNDEF (mask propagated)
    r = a.count(v, min_count: 10)
    assert(r.has_mask?)
    assert_equal([true, true, true], r.is_masked.to_a)
  end

  def test_fill_value_forwarded
    a = CArray.int32(10).seq
    v = CArray.int32(3); v[0]=0; v[1]=1; v[2]=2
    r = a.count(v, min_count: 100, fill_value: -1)
    assert_equal([-1, -1, -1], r.to_a)
  end

  # ---- bool self + CArray v rejected ----------------------------------

  def test_bool_self_carray_v_raises
    b = CArray.int32(5).seq.ne(0)   # boolean
    v = CArray.boolean(2)
    assert_raise(TypeError) { b.count(v) }
  end

  # ---- consistency: each output cell matches scalar count -------------

  def test_consistency_with_scalar_count
    a = CArray.int32(20).seq.mod(5)
    v = CArray.int32(4); v[0]=0; v[1]=2; v[2]=4; v[3]=99
    r = a.count(v)
    [0, 1, 2, 3].each do |k|
      assert_equal(a.count(v[k]), r[k],
                   "broadcast[#{k}] != scalar count(#{v[k]})")
    end
  end

  def test_consistency_with_scalar_count_per_axis
    a = CArray.int32(3, 5).seq.mod(4)
    v = CArray.int32(2); v[0]=1; v[1]=3
    r = a.count(v, axis: 0)   # shape [5, 2]
    5.times do |i|
      # a[nil, i] is CABlock whose #count is attribute accessor (= pre-
      # existing namespace collision documented in CF.2).  Use copy to
      # materialise into an entity CArray before count(v) (to_ca returns
      # the view itself, which still has the colliding #count accessor).
      col = a[nil, i].copy
      2.times do |k|
        assert_equal(col.count(v[k]), r[i, k],
                     "[#{i},#{k}] mismatch")
      end
    end
  end
end
