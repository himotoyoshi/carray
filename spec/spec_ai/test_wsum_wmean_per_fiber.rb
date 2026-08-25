require 'test/unit'
require 'carray'

# ============================================================
# MkKernel.reduce array_arg path acceptance expansion test
# (PROPOSAL_REDUCTION_PER_FIBER_AUX_OPERAND rev1)
#
# acceptance set (= 3 forms):
#   W-A1  scalar / 0-D / single-element CArray  -> 全要素同重み
#   W-A2  1-D length self.dim[axes[0]]          -> reduce 軸 axis-broadcast
#   W-A3  N-D shape == self.shape                -> per-element (= 既存 path)
#   else                                          -> raise
#
# Baseline (= 既存 W-A3 path) は test_w2_wsum.rb / test_w3_wmean.rb で pin 済。
# 本 file は W-A1 / W-A2 拡張 + WR1〜WR5 reject case を pin。
# ============================================================

class TestWsumWmeanPerFiber < Test::Unit::TestCase

  # ----------------------------------------------------------------
  # W-A1: scalar / 0-D / single-element CArray
  # ----------------------------------------------------------------

  def test_W_A1_scalar_numeric_wsum_1d
    a = CArray.float64(5).seq!(1.0, 1.0)   # [1, 2, 3, 4, 5]
    # wsum with scalar weight 2.0 == 2 * sum(a) == 2 * 15 == 30
    assert_in_delta(30.0, a.wsum(2.0), 1e-12)
  end

  def test_W_A1_scalar_numeric_wmean_1d
    a = CArray.float64(5).seq!(1.0, 1.0)
    # wmean with scalar weight 2.0 == mean(a) == 3.0 (= weight cancels)
    assert_in_delta(3.0, a.wmean(2.0), 1e-12)
  end

  def test_W_A1_scalar_numeric_wsum_2d_axis
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    # a = [[1,2,3], [4,5,6]]
    # wsum(2.0, axis: 0) == 2 * a.sum(axis: 0) == 2 * [5, 7, 9] == [10, 14, 18]
    assert_equal([10.0, 14.0, 18.0], a.wsum(2.0, axis: 0).to_a)
  end

  def test_W_A1_scalar_numeric_wsum_3d_axis_mid
    a = CArray.float64(2, 3, 2) { |i, j, k| 1.0 + i * 6 + j * 2 + k }
    # axis: 1 reduce. Expected = 2 * a.sum(axis: 1)
    expected = (a * 2).sum(axis: 1).to_a
    assert_equal(expected, a.wsum(2.0, axis: 1).to_a)
  end

  def test_W_A1_zero_d_carray
    a = CArray.float64(5).seq!(1.0, 1.0)
    cs = CScalar.float64
    cs[0] = 2.0
    # CScalar (= elements==1) routes to scalar path
    assert_in_delta(30.0, a.wsum(cs), 1e-12)
  end

  def test_W_A1_single_element_carray
    a = CArray.float64(5).seq!(1.0, 1.0)
    w_1x1 = CArray.float64(1) { 2.0 }   # 1-D length 1 = single element
    assert_in_delta(30.0, a.wsum(w_1x1), 1e-12)
  end

  # ----------------------------------------------------------------
  # W-A2: 1-D length self.dim[axes[0]] (axis-broadcast)
  # ----------------------------------------------------------------

  def test_W_A2_1d_axis_broadcast_2d_axis0
    a = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    w_1d = CArray.float64(3) { |i| (i + 1).to_f }   # [1, 2, 3] along axis 0
    # axis 0 reduce: per-column sum of (a[i, j] * w[i])
    # col 0: 0*1 + 10*2 + 20*3 = 0 + 20 + 60 = 80
    # col 1: 1*1 + 11*2 + 21*3 = 1 + 22 + 63 = 86
    # col 2: 2*1 + 12*2 + 22*3 = 2 + 24 + 66 = 92
    # col 3: 3*1 + 13*2 + 23*3 = 3 + 26 + 69 = 98
    assert_equal([80.0, 86.0, 92.0, 98.0], a.wsum(w_1d, axis: 0).to_a)
  end

  def test_W_A2_1d_axis_broadcast_2d_axis1
    a = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    w_1d = CArray.float64(4) { |j| (j + 1).to_f }   # [1, 2, 3, 4] along axis 1
    # axis 1 reduce: per-row sum of (a[i, j] * w[j])
    # row 0: 0*1 + 1*2 + 2*3 + 3*4 = 0+2+6+12 = 20
    # row 1: 10*1 + 11*2 + 12*3 + 13*4 = 10+22+36+52 = 120
    # row 2: 20*1 + 21*2 + 22*3 + 23*4 = 20+42+66+92 = 220
    assert_equal([20.0, 120.0, 220.0], a.wsum(w_1d, axis: 1).to_a)
  end

  def test_W_A2_1d_axis_broadcast_wmean
    a = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    w_1d = CArray.float64(4) { |j| 1.0 }   # uniform weights
    # uniform weights -> wmean == mean(axis=1)
    r = a.wmean(w_1d, axis: 1)
    assert_equal(3, r.dim[0])
    expected = a.mean(axis: 1).to_a
    r.to_a.each_with_index do |v, i|
      assert_in_delta(expected[i], v, 1e-12)
    end
  end

  def test_W_A2_1d_axis_broadcast_3d_axis_last
    a = CArray.float64(2, 3, 4) { |i, j, k| (i * 100 + j * 10 + k).to_f }
    w_1d = CArray.float64(4) { |k| 1.0 + k }   # [1, 2, 3, 4] along axis 2
    r = a.wsum(w_1d, axis: -1)
    assert_equal([2, 3], r.dim)
    # verify: r[i, j] = sum_k a[i,j,k] * w[k]
    2.times do |i|
      3.times do |j|
        expected = (0...4).sum { |k| (i * 100 + j * 10 + k) * (1.0 + k) }
        assert_in_delta(expected, r[i, j], 1e-12,
                        "wsum axis-broadcast r[#{i},#{j}]")
      end
    end
  end

  # ----------------------------------------------------------------
  # W-A3 既存 path 維持 (= regression なし)
  # ----------------------------------------------------------------

  def test_W_A3_full_shape_unchanged
    # 既存 test_w2_wsum.rb と同 case を pin、本 phase で挙動不変
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    w = CArray.float64(2, 3) { 1.0 }
    assert_equal([5.0, 7.0, 9.0], a.wsum(w, axis: 0).to_a)
    assert_equal([6.0, 15.0], a.wsum(w, axis: 1).to_a)
  end

  def test_W_A3_multi_axis_unchanged
    a = CArray.float64(2, 2, 2) { |i, j, k| 1.0 + i * 4 + j * 2 + k }
    w = CArray.float64(2, 2, 2) { 1.0 }
    assert_equal([10.0, 26.0], a.wsum(w, axis: [1, 2]).to_a)
  end

  # ----------------------------------------------------------------
  # WR1〜WR5: reject cases
  # ----------------------------------------------------------------

  def test_WR1_intermediate_ndim_rejected
    # self.ndim=3, w.ndim=2 (= 1 < ndim < 3、self.ndim と一致しない、length も axis 不一致)
    a = CArray.float64(4, 5, 6) { 0.0 }
    w = CArray.float64(5, 6) { 1.0 }
    assert_raise do
      a.wsum(w, axis: -1)
    end
  end

  def test_WR2_same_ndim_shape_mismatch
    a = CArray.float64(4, 5, 6) { 0.0 }
    w = CArray.float64(4, 5, 7) { 1.0 }   # dim[2]=7 != self.dim[2]=6
    assert_raise do
      a.wsum(w, axis: -1)
    end
  end

  def test_WR3_1d_length_mismatch
    a = CArray.float64(4, 5, 6) { 0.0 }
    w = CArray.float64(7) { 1.0 }   # length 7 != self.dim[-1]=6
    assert_raise do
      a.wsum(w, axis: -1)
    end
  end

  def test_WR4_multi_axis_with_1d_weight
    a = CArray.float64(4, 5, 6) { 0.0 }
    w = CArray.float64(6) { 1.0 }   # 1-D weight + multi-axis reduce
    # multi-axis reduce で 1-D weight は ambiguous → reject
    assert_raise do
      a.wsum(w, axis: [1, 2])
    end
  end

  def test_WR5_size1_broadcast_rejected
    a = CArray.float64(4, 5, 6) { 0.0 }
    w = CArray.float64(1, 5, 6) { 1.0 }   # axis 0 size-1 broadcast
    assert_raise do
      a.wsum(w, axis: -1)
    end
  end

  # ----------------------------------------------------------------
  # correctness: W-A1 / W-A2 materialize と W-A3 直接 path で同 result
  # ----------------------------------------------------------------

  def test_correctness_W_A1_scalar_eq_full_const
    a = CArray.float64(4, 5, 6) { |i, j, k| (i + j + k).to_f }
    r_a1 = a.wsum(2.0, axis: -1)
    r_a3 = a.wsum(CArray.float64(4, 5, 6) { 2.0 }, axis: -1)
    r_a1.to_a.flatten.each_with_index do |v, i|
      assert_in_delta(r_a3.to_a.flatten[i], v, 1e-12)
    end
  end

  def test_correctness_W_A2_1d_eq_broadcast_full
    a = CArray.float64(4, 5, 6) { |i, j, k| (i + j + k).to_f }
    w_1d = CArray.float64(6) { |k| 1.0 + k }
    w_full = CArray.float64(4, 5, 6) { |i, j, k| 1.0 + k }   # broadcast manually
    r_a2 = a.wsum(w_1d, axis: -1)
    r_a3 = a.wsum(w_full, axis: -1)
    r_a2.to_a.flatten.each_with_index do |v, i|
      assert_in_delta(r_a3.to_a.flatten[i], v, 1e-12)
    end
  end

  # ----------------------------------------------------------------
  # boundary: self 1-D (= W-A2 と W-A3 が degenerate)
  # ----------------------------------------------------------------

  def test_self_1d_w_1d_degenerate
    # self.ndim==1 で w 1-D length == self.length は W-A2 と W-A3 が同形
    # algorithm priority で W-A3 commit → 既存 path、result 不変
    a = CArray.float64(5).seq!(1.0, 1.0)   # [1, 2, 3, 4, 5]
    w = CArray.float64(5) { |i| (i + 1).to_f }
    # wsum = 1*1 + 2*2 + 3*3 + 4*4 + 5*5 = 1+4+9+16+25 = 55
    assert_in_delta(55.0, a.wsum(w), 1e-12)
  end
end
