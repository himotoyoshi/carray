# test_gather_nd.rb
#
# Tests for CArray#gather_nd / CArray#put_nd
# (= N-D arbitrary-position gather/scatter, take_along_axis の N-D 拡張)

$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

class TestGatherNd < Test::Unit::TestCase

  # ---------- gather_nd: scalar gather (K = ndim) ----------

  def test_gather_nd_1d_scalar
    a = CArray.float64(5).seq             # [0,1,2,3,4]
    idx = CA_INT64([[2], [0], [4]])       # shape (3, 1), K=1, outer=(3,)
    g = a.gather_nd(idx)
    assert_equal [3], g.shape
    assert_equal [2.0, 0.0, 4.0], g.to_a
  end

  def test_gather_nd_2d_scalar
    a = CArray.float64(3, 4).seq          # 0..11
    idx = CA_INT64([[0, 1], [1, 3], [2, 0]])  # shape (3, 2), K=2
    g = a.gather_nd(idx)
    assert_equal [3], g.shape
    assert_equal [1.0, 7.0, 8.0], g.to_a
  end

  def test_gather_nd_3d_scalar
    a = CArray.int32(2, 2, 2).seq         # 0..7 (flat = i*4 + j*2 + k)
    idx = CA_INT64([[0, 1, 0], [1, 0, 1], [1, 1, 1]])  # shape (3, 3), K=3
    g = a.gather_nd(idx)
    assert_equal [3], g.shape
    assert_equal [2, 5, 7], g.to_a
  end

  def test_gather_nd_2d_outer_2d
    # outer は 1-D に限らない (= indices.shape = (..., K) で ... 任意)
    a = CArray.float64(4, 4).seq          # 0..15
    idx = CA_INT64([[[0, 0], [1, 1]],
                    [[2, 2], [3, 3]]])    # shape (2, 2, 2), K=2, outer=(2,2)
    g = a.gather_nd(idx)
    assert_equal [2, 2], g.shape
    assert_equal [[0.0, 5.0], [10.0, 15.0]], g.to_a
  end

  # ---------- gather_nd: sub-array gather (K < ndim, rest 非空) ----------

  def test_gather_nd_sub_array_row
    a = CArray.float64(3, 4).seq          # rows are sub-arrays of shape (4,)
    idx = CA_INT64([[0], [2]])            # shape (2, 1), K=1, outer=(2,), rest=(4,)
    g = a.gather_nd(idx)
    assert_equal [2, 4], g.shape
    assert_equal [[0.0, 1.0, 2.0, 3.0], [8.0, 9.0, 10.0, 11.0]], g.to_a
  end

  def test_gather_nd_sub_array_3d
    # params (2, 3, 4): K=1 で (3, 4) sub-array を 2 枚 gather
    a = CArray.int32(2, 3, 4).seq
    idx = CA_INT64([[1], [0]])            # shape (2, 1), K=1, outer=(2,), rest=(3,4)
    g = a.gather_nd(idx)
    assert_equal [2, 3, 4], g.shape
    assert_equal a[1, nil, nil].to_a, g[0, nil, nil].to_a
    assert_equal a[0, nil, nil].to_a, g[1, nil, nil].to_a
  end

  def test_gather_nd_sub_array_k2_rest1
    # params (3, 4, 5): K=2 で (5,) sub-array を gather
    a = CArray.int32(3, 4, 5).seq
    idx = CA_INT64([[0, 1], [2, 3]])      # shape (2, 2), K=2, outer=(2,), rest=(5,)
    g = a.gather_nd(idx)
    assert_equal [2, 5], g.shape
    assert_equal a[0, 1, nil].to_a, g[0, nil].to_a
    assert_equal a[2, 3, nil].to_a, g[1, nil].to_a
  end

  # ---------- gather_nd: duplicate coords OK ----------

  def test_gather_nd_duplicate_coords_ok
    a = CArray.float64(3, 3).seq
    idx = CA_INT64([[1, 1], [1, 1], [0, 2]])
    g = a.gather_nd(idx)
    assert_equal [4.0, 4.0, 2.0], g.to_a
  end

  # ---------- gather_nd: negative indices wrap ----------

  def test_gather_nd_negative_indices
    a = CArray.float64(3, 4).seq
    idx = CA_INT64([[-1, -1], [0, -2]])   # (-1, -1) = (2, 3); (0, -2) = (0, 2)
    g = a.gather_nd(idx)
    assert_equal [11.0, 2.0], g.to_a
  end

  # ---------- gather_nd: error paths ----------

  def test_gather_nd_k_exceeds_ndim
    a = CArray.float64(3, 3).seq
    idx = CA_INT64([[0, 1, 2]])           # K=3, ndim=2
    assert_raise(ArgumentError) { a.gather_nd(idx) }
  end

  def test_gather_nd_oob_raises
    a = CArray.float64(3, 3).seq
    idx = CA_INT64([[5, 0]])              # 5 OOB on first axis (size 3)
    assert_raise(IndexError) { a.gather_nd(idx) }
  end

  def test_gather_nd_indices_bad_type
    # neither a CArray nor an Array of per-axis coordinates
    a = CArray.float64(3, 3).seq
    assert_raise(ArgumentError) { a.gather_nd("nope") }
  end

  def test_gather_nd_per_axis_bad_entry
    # per-axis list entries must be CArray or Integer
    a = CArray.float64(3, 3).seq
    assert_raise(ArgumentError) { a.gather_nd([CA_INT64([0, 1]), "x"]) }
  end

  def test_gather_nd_per_axis_rejects_ruby_array_entry
    # Ruby Array coordinates are rejected: this is a copy-free gather path,
    # wrap array literals with CA_INT64 yourself.
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a.gather_nd([[0, 2]]) }
  end

  # ---------- per-axis form: Array of coordinate arrays ----------

  def test_gather_nd_per_axis_matches_stacked
    a = CArray.float64(3, 4).seq
    i = CA_INT64([0, 1, 2])
    j = CA_INT64([1, 3, 0])
    per_axis = a.gather_nd([i, j])
    stacked  = a.gather_nd(CArray.stack([i, j], axis: -1))
    assert_equal [1.0, 7.0, 8.0], per_axis.to_a
    assert_equal stacked.to_a, per_axis.to_a
  end

  def test_gather_nd_per_axis_broadcast
    # i (2,1) and j (1,3) broadcast to a (2,3) outer shape.
    a = CArray.float64(3, 4).seq
    i = CA_INT64([[0], [2]])
    j = CA_INT64([[0, 1, 3]])
    g = a.gather_nd([i, j])
    assert_equal [2, 3], g.shape
    assert_equal [[0.0, 1.0, 3.0], [8.0, 9.0, 11.0]], g.to_a
  end

  def test_gather_nd_per_axis_scalar_axis
    # an Integer scalar on one axis broadcasts to the common shape.
    a = CArray.float64(3, 4).seq
    g = a.gather_nd([CA_INT64([0, 1, 2]), 2])
    assert_equal [2.0, 6.0, 10.0], g.to_a
  end

  def test_gather_nd_per_axis_sub_array
    # K < ndim in per-axis form: rest axis is carried through.
    a = CArray.float64(3, 4).seq
    g = a.gather_nd([CA_INT64([0, 2])])   # K=1, rest=(4,)
    assert_equal [2, 4], g.shape
    assert_equal [[0.0, 1.0, 2.0, 3.0], [8.0, 9.0, 10.0, 11.0]], g.to_a
  end

  def test_gather_nd_per_axis_all_scalar
    # all-scalar list == single-coordinate degenerate form -> (1,) result.
    a = CArray.int32(3, 4) { |i, j| i * 10 + j }
    g = a.gather_nd([2, 3])
    assert_equal [1], g.shape
    assert_equal [23], g.to_a
  end

  def test_put_nd_per_axis
    a = CArray.float64(3, 4).seq
    a.put_nd([CA_INT64([0, 1]), CA_INT64([1, 2])], CA_DOUBLE([100, 200]))
    assert_equal 100.0, a[0, 1]
    assert_equal 200.0, a[1, 2]
  end

  def test_gather_nd_rejects_float_indices
    # non-integer indices must raise rather than silently truncate via
    # float % / int64 cast (coordinates must be exact integers).
    a = CArray.float64(3, 3).seq
    assert_raise(ArgumentError) { a.gather_nd(CA_DOUBLE([[1.9, 2.1]])) }
  end

  def test_put_nd_rejects_float_indices
    a = CArray.float64(3, 3).seq
    assert_raise(ArgumentError) { a.put_nd(CA_DOUBLE([[0.0, 1.0]]), 5.0) }
  end

  def test_gather_nd_single_coordinate_1d_indices
    # 1-D indices (K,) with K == ndim, outer = [] and rest = []: documented
    # to return a 1-element (1,) CArray (CArray scalar model), not 0-dim.
    a = CArray.int32(3, 4) { |i, j| i * 10 + j }
    g = a.gather_nd(CA_INT64([2, 3]))   # coord (2,3) -> 23
    assert_equal [1], g.shape
    assert_equal [23], g.to_a
  end

  def test_gather_nd_accepts_narrow_integer_indices
    # any integer width is accepted (cast up internally), only non-integer
    # is rejected.
    a = CArray.float64(3, 4).seq
    g = a.gather_nd(CA_INT8([[0, 1], [2, 3]]))
    assert_equal [1.0, 11.0], g.to_a
  end

  # ---------- put_nd: scalar scatter ----------

  def test_put_nd_basic
    a = CArray.float64(3, 4).seq
    idx = CA_INT64([[0, 0], [1, 2], [2, 3]])
    vals = CA_FLOAT([100.0, 200.0, 300.0])
    a.put_nd(idx, vals)
    assert_equal 100.0, a[0, 0]
    assert_equal 200.0, a[1, 2]
    assert_equal 300.0, a[2, 3]
    # untouched
    assert_equal 1.0, a[0, 1]
  end

  def test_put_nd_returns_self
    a = CArray.float64(3, 4).seq
    idx = CA_INT64([[0, 0]])
    vals = CA_FLOAT([99.0])
    result = a.put_nd(idx, vals)
    assert_same a, result
  end

  def test_put_nd_scalar_broadcast
    # scalar value broadcasts across all coords
    a = CArray.int32(3, 4).seq
    idx = CA_INT64([[0, 0], [1, 1], [2, 2]])
    a.put_nd(idx, 0)
    assert_equal 0, a[0, 0]
    assert_equal 0, a[1, 1]
    assert_equal 0, a[2, 2]
  end

  def test_put_nd_duplicate_last_write_wins
    # duplicate coords: last write wins (CAMapping xfer_addrs semantic).
    # NOTE: 順序は実装依存だが、同一 address に複数値を投入する operation
    # 自体は受け入れる (= NotImplementedError にしない).
    a = CArray.int32(3, 3) { 0 }
    idx = CA_INT64([[1, 1], [1, 1], [1, 1]])
    vals = CA_INT32([10, 20, 30])
    a.put_nd(idx, vals)
    # cell (1,1) は 10/20/30 のいずれか.  少なくとも 0 ではない.
    assert_not_equal 0, a[1, 1]
    assert_true [10, 20, 30].include?(a[1, 1])
  end

  # ---------- gather_nd + put_nd: round-trip ----------

  def test_gather_nd_put_nd_round_trip
    a = CArray.float64(4, 5).seq
    idx = CA_INT64([[0, 1], [2, 3], [3, 4]])
    g = a.gather_nd(idx)             # [1, 13, 19]
    b = CArray.float64(4, 5) { 0 }
    b.put_nd(idx, g)
    # b は coord 位置のみ a と同じ
    assert_equal a[0, 1], b[0, 1]
    assert_equal a[2, 3], b[2, 3]
    assert_equal a[3, 4], b[3, 4]
    assert_equal 0.0, b[0, 0]
  end

  # ---------- gather_nd: non-contig params (transpose view) ----------

  def test_gather_nd_on_transpose_view
    base = CArray.int32(3, 4).seq
    a = base.transpose                # shape (4, 3), non-contig
    idx = CA_INT64([[0, 1], [3, 2]])  # 座標を transposed 上で解釈
    g = a.gather_nd(idx)
    # a[0,1] == base[1,0] == 4; a[3,2] == base[2,3] == 11
    assert_equal [4, 11], g.to_a
  end

end
