require 'test/unit'
require 'carray'

# ============================================================
# MkKernel.search family per-fiber matched acceptance test
# (PROPOSAL_LINEAR_INTERP_PER_FIBER_MATCHED rev4)
#
# acceptance set (= 5 forms):
#   A1   scalar / 0-D                 -> axis k removed
#   A2   1-D length M shared          -> axis k -> M
#   A2.5 N-D base_shape per-fiber     -> axis k removed
#   A3   N-D self_shape with axis k free -> axis k -> M
#   A4   view variants of above
#
# baseline cases (= A1, A2, A2.5) pass on master AND rev4.
# new cases (= A3, R1-R8 reject) fail on master, pass on rev4.
# ============================================================

class TestSearchFamilyPerFiber < Test::Unit::TestCase

  # ----------------------------------------------------------------
  # Baseline: A1 scalar / 0-D val (target axis removed)
  # ----------------------------------------------------------------

  def test_A1_scalar_linear_fetch_innermost
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }
    r = self_3d.linear_fetch(2.5, axis: -1)
    assert_equal [4, 5], r.dim
    assert_in_delta 2.5, r[0, 0], 1e-12
  end

  def test_A1_scalar_linear_section_mid_axis
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| j.to_f }
    r = self_3d.linear_section(2.5, axis: 1)
    assert_equal [4, 6], r.dim
    assert_in_delta 2.5, r[0, 0], 1e-12
  end

  def test_A1_zerodim_carray_search
    self_3d = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    r = self_3d.search(CA_FLOAT64(11.0), axis: 1)
    assert_equal [3], r.dim
  end

  # ----------------------------------------------------------------
  # Baseline: A2 1-D shared M-query (axis k -> M)
  # ----------------------------------------------------------------

  def test_A2_1d_shared_linear_section
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }
    val = CArray.float64(3) { |i| [1.5, 3.0, 4.5][i] }
    r = self_3d.linear_section(val, axis: -1)
    assert_equal [4, 5, 3], r.dim
  end

  def test_A2_1d_shared_search_M_not_equal_target
    # self [3, 4] axis 1, val [2] (M=2 != self.dim[1]=4 AND != base_shape[0]=3)
    # -> A2 shared, result [3, 2]
    b = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    val = CArray.float64(2) { |i| [1.0, 99.0][i] }
    r = b.search_nearest(val, axis: 1)
    assert_equal [3, 2], r.dim
  end

  # ----------------------------------------------------------------
  # Baseline: A2.5 base_shape per-fiber scalar (axis k removed)
  # rev5: ndim>=2 限定 (= base_ndim >= 2 必須、self.ndim >= 3 のみ自動 trigger)
  # ----------------------------------------------------------------

  def test_A25_base_shape_2d_linear_fetch
    # self [4, 5, 6] axis -1, val [4, 5] (= base_shape ndim=2) -> A2.5 per-fiber scalar
    # 各 (i,j) cell に 1 個 query
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }
    val = CArray.float64(4, 5) { |i, j| ((i + j) % 6).to_f }
    r = self_3d.linear_fetch(val, axis: -1)
    assert_equal [4, 5], r.dim
    4.times do |i|
      5.times do |j|
        assert_in_delta ((i + j) % 6).to_f, r[i, j], 1e-12,
                        "linear_fetch self[i,j,k]=k, val[i,j]=(i+j)%6 -> r[i,j]"
      end
    end
  end

  def test_A25_base_shape_axis_mid
    # self [4, 5, 6] axis 1, val [4, 6] (= base_shape ndim=2) -> A2.5
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| j.to_f }
    val = CArray.float64(4, 6) { |i, k| 2.5 }
    r = self_3d.linear_fetch(val, axis: 1)
    assert_equal [4, 6], r.dim
  end

  def test_A25_per_fiber_scalar_2d_self_via_explicit_reshape
    # rev5: self.ndim==2 で per-fiber scalar は explicit reshape (= [N, 1]) で
    # A3 (with M=1) に誘導、result [N, 1] (= squeeze で [N])
    b = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    val_pf = CArray.float64(3, 1) { |i, _| [1.0, 11.0, 21.0][i] }   # A3 with M=1
    r = b.search(val_pf, axis: 1)
    assert_equal [3, 1], r.dim
    assert_equal [[1], [1], [1]], r.to_a
    # squeeze で [N] にできる:
    r_flat = r.flatten
    assert_equal [3], r_flat.dim
    assert_equal [1, 1, 1], r_flat.to_a
  end

  # ----------------------------------------------------------------
  # rev4 new: A3 N-D per-fiber M-query (axis k -> M)
  # ----------------------------------------------------------------

  def test_A3_per_fiber_M_query_linear_fetch_innermost
    # 気象 regrid pipeline: self [4, 5, 6] axis -1, val [4, 5, 3] -> [4, 5, 3]
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }
    val = CArray.float64(4, 5, 3) { |i, j, m| (m * 2 + 0.5).to_f }
    r = self_3d.linear_fetch(val, axis: -1)
    assert_equal [4, 5, 3], r.dim
    4.times do |i|
      5.times do |j|
        3.times do |m|
          assert_in_delta (m * 2 + 0.5).to_f, r[i, j, m], 1e-12,
                          "A3 per-fiber: r[#{i},#{j},#{m}] from val[#{i},#{j},#{m}]"
        end
      end
    end
  end

  def test_A3_per_fiber_M_query_axis_mid
    # self [4, 5, 6] axis 1, val [4, 7, 6] -> [4, 7, 6]
    self_3d = CArray.float64(4, 5, 6) { |i, j, k| j.to_f }
    val = CArray.float64(4, 7, 6) { |i, m, k| (m * 0.5).to_f }
    r = self_3d.linear_fetch(val, axis: 1)
    assert_equal [4, 7, 6], r.dim
  end

  def test_A3_per_fiber_M_query_2d
    # self [3, 4] axis 1, val [3, 5] -> [3, 5]
    b = CArray.float64(3, 4) { |i, j| j.to_f }
    val = CArray.float64(3, 5) { |i, m| m * 0.5 }
    r = b.linear_fetch(val, axis: 1)
    assert_equal [3, 5], r.dim
  end

  def test_A3_per_fiber_M_query_search_family
    # search family も同 path で動くこと
    self_3d = CArray.float64(3, 4, 5) { |i, j, k| (i * 100 + j * 10 + k).to_f }
    val = CArray.float64(3, 4, 2) { |i, j, m| (i * 100 + j * 10 + m).to_f }
    r = self_3d.bsearch(val, axis: -1)
    assert_equal [3, 4, 2], r.dim
    3.times { |i| 4.times { |j| 2.times { |m|
      assert_equal m, r[i, j, m]
    }}}
  end

  # ----------------------------------------------------------------
  # rev4 new: R1-R8 reject cases
  # ----------------------------------------------------------------

  def test_R1_ndim_mismatch_outer_product_removed
    # val.ndim ∈ {0, 1, ndim-1, ndim} のいずれでもない -> raise
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(7, 3)   # ndim=2、self.ndim=3、self.ndim-1=2 だが base != [7,3]
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R2_partial_prefix_base_ndim
    # val.ndim == self.ndim-1 だが val.shape != base_shape
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(5, 7)   # ndim=2 = base_ndim、しかし base=[4,5]
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R3_partial_match_self_ndim_axis_transpose
    # val.ndim == self.ndim だが非 target 軸位置で size 不一致 (= 軸転置)
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(5, 4, 3)   # axis 0=5 != self[0]=4
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R3_partial_match_self_ndim_nontarget_size
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(4, 8, 3)   # axis 1=8 != self[1]=5
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R4_size1_broadcast_rejected
    # size-1 broadcast prefix -> reject (implicit broadcast 規律)
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(1, 5, 3)   # axis 0 size-1 broadcast
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R5_empty_query_A3_path
    # val.dim[k] == 0 (A3 path) -> reject
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(4, 5, 0)
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  def test_R5_empty_query_A2_path
    # val.dim[0] == 0 (A2 path) -> reject
    self_3d = CArray.float64(4, 5, 6)
    val = CArray.float64(0)
    assert_raise(ArgumentError) do
      self_3d.linear_fetch(val, axis: -1)
    end
  end

  # ----------------------------------------------------------------
  # rev5 boundary: self.ndim==2 で val 1-D は無条件 A2 (= length が
  # base_shape と coincide しても shared、§3.1 統一 rule preserve)
  # ----------------------------------------------------------------

  def test_boundary_ndim2_val1d_length_eq_base_shared
    # rev5: self [3, 4] axis 1, val [3] -> A2 shared M=3 (= rev4 では A2.5 だった)
    # §3.1 統一 rule: axis 1 (= length 4) を val.length (= 3) に差し替え -> [3, 3]
    b = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    val = CArray.float64(3) { |i| (i * 10).to_f }
    r = b.search(val, axis: 1)
    assert_equal [3, 3], r.dim   # A2 shared (rev5)
    # S1: no-match -> UNDEF
    # b[0]=[0,1,2,3] vs query [0, 10, 20] -> [0, x, x]
    # b[1]=[10,11,12,13] vs query [0, 10, 20] -> [x, 0, x]
    # b[2]=[20,21,22,23] vs query [0, 10, 20] -> [x, x, 0]
    assert_equal [[0, UNDEF, UNDEF], [UNDEF, 0, UNDEF], [UNDEF, UNDEF, 0]], r.to_a
  end

  def test_boundary_ndim2_val1d_length_neq_base
    # self [3, 4] axis 1, val [2] (= 1-D) -> A2 shared
    b = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    val = CArray.float64(2) { |i| [1.0, 99.0][i] }
    r = b.search_nearest(val, axis: 1)
    assert_equal [3, 2], r.dim   # A2 (shared M=2)
  end

  # ----------------------------------------------------------------
  # rev4 boundary: 1-D self + 1-D val (degenerate)
  # ----------------------------------------------------------------

  def test_boundary_self_1d_val_1d
    # self [6] axis 0, val [3] -> A2 shared (base_ndim=0 なので A2.5 path 不可)
    self_1d = CArray.float64(6).seq!(0.0, 1.0)
    val = CArray.float64(3) { |i| [1.5, 3.0, 4.5][i] }
    r = self_1d.linear_fetch(val, axis: 0)
    assert_equal [3], r.dim
  end

  # ----------------------------------------------------------------
  # rev4: view source (CABlock / CAStride / CARefer) per-fiber 透過
  # ----------------------------------------------------------------

  def test_view_source_block_a3
    self_4d = CArray.float64(8, 5, 6) { |i, j, k| k.to_f }
    self_3d_view = self_4d[0..3, nil, nil]   # CABlock view shape [4, 5, 6]
    val = CArray.float64(4, 5, 3) { |i, j, m| m.to_f }
    r = self_3d_view.linear_fetch(val, axis: -1)
    assert_equal [4, 5, 3], r.dim
  end
end
