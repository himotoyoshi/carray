# frozen_string_literal: true
#
# spec_ai/test_search_form_demo.rb
#
# S.1.3: formal test suite for the mkkernel search form demo kernel
# (= find_value_index_ki).  Coverage:
#   - case A (scalar val) across all 10 numeric data_types
#   - case C exact (val.shape == base_shape)
#   - case C general broadcast (val.shape with size-1 dims)
#   - case B (val.shape doesn't broadcast -> tail append)
#   - vectorized 1-D (base_ndim = 0)
#   - data_type cast (val data_type != self data_type, auto-cast)
#   - mask global raise (mask_self: :raise)
#   - axis negative / out-of-range
#   - 0-D output rejection
#
# Pin behavior for S.1 framework; production family kernels (S.2-S.4)
# will replace these with bsearch / search / search_nearest using the
# same DSL form.

require "test/unit"
require_relative "../../lib/carray"

class TestSearchFormDemo < Test::Unit::TestCase
  # ----------------------------------------------------------------
  # Case A: scalar val (= Ruby Integer / Float, not CArray)
  # ----------------------------------------------------------------

  ALL_NUMERIC = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
                   float32 float64]

  def test_case_a_scalar_1d_match_all_data_types
    ALL_NUMERIC.each do |data_type|
      a = CArray.send(data_type, 5).seq!(0, 1)   # [0, 1, 2, 3, 4]
      assert_equal 2, a.find_value_index_ki(2, 0), "data_type=#{data_type} match"
      assert_equal 0, a.find_value_index_ki(0, 0), "data_type=#{data_type} first"
      assert_equal 4, a.find_value_index_ki(4, 0), "data_type=#{data_type} last"
    end
  end

  def test_case_a_scalar_1d_no_match
    ALL_NUMERIC.each do |data_type|
      a = CArray.send(data_type, 5).seq!(0, 1)
      assert_nil a.find_value_index_ki(99, 0), "data_type=#{data_type}"
    end
  end

  def test_case_a_scalar_2d_axis_0
    a = CArray.float64(3, 4).seq!(0, 1)
    # a = [[0,1,2,3], [4,5,6,7], [8,9,10,11]]
    # axis=0 search for 6.0: col 2, row 1
    r = a.find_value_index_ki(6.0, 0)
    assert_equal [4],            r.dim
    assert_equal [UNDEF, UNDEF, 1, UNDEF], r.to_a   # S1: no-match -> UNDEF
  end

  def test_case_a_scalar_2d_axis_1
    a = CArray.float64(3, 4).seq!(0, 1)
    # axis=1 search for 6.0: row 1 at col 2
    r = a.find_value_index_ki(6.0, 1)
    assert_equal [3],          r.dim
    assert_equal [UNDEF, 2, UNDEF],  r.to_a
  end

  def test_case_a_scalar_3d_middle_axis
    a = CArray.float64(2, 3, 4).seq!(0, 1)
    # a[i,j,k] = i*12 + j*4 + k -> a[1,2,3] = 23
    # axis=1 search for 14.0: at (i=1, k=2), j=0 gives 12, j=1 gives 16, j=2 gives 20
    # Actually 14 = 1*12 + j*4 + 2 -> j = 0 → 14? 12+0+2=14. Yes j=0 for (1,_,2)
    r = a.find_value_index_ki(14.0, 1)
    assert_equal [2, 4], r.dim
    # i=0, k=*: a[0, j, k] = j*4 + k, search 14 -> 14 - k = 4*j -> j must be int
    #   k=0: 14 = 4*j -> j=3.5 no
    #   k=1: 13 = 4*j -> no
    #   k=2: 12 = 4*j -> j=3 but j<3 (dim=3) -> no
    #   k=3: 11 = 4*j -> no
    # i=1, k=0: 14 - 0 = 14 -> j=3.5 no
    #   k=1: 13 -> no
    #   k=2: 12 -> j=3 -> no (dim=3, j range 0..2)
    #   k=3: 11 -> no
    # Hmm let me recompute. a[i,j,k] = i*12 + j*4 + k (3-D row-major seq)
    # For axis=1, slab varies j, so search for 14 in {i*12 + j*4 + k : j in 0..2}
    # i=0: {j*4 + k for j in 0..2} = {k, k+4, k+8}, k=0..3
    #   k=0: {0, 4, 8} -> no 14
    #   k=1: {1, 5, 9} -> no
    #   k=2: {2, 6, 10} -> no
    #   k=3: {3, 7, 11} -> no
    # i=1: {12 + j*4 + k for j in 0..2} = {12+k, 16+k, 20+k}
    #   k=0: {12, 16, 20} -> no 14
    #   k=1: {13, 17, 21} -> no
    #   k=2: {14, 18, 22} -> match j=0 at (i=1, k=2)
    #   k=3: {15, 19, 23} -> no
    expected = [
      [UNDEF, UNDEF, UNDEF, UNDEF],   # i=0
      [UNDEF, UNDEF,  0, UNDEF],   # i=1 (match at j=0, k=2)
    ]
    assert_equal expected, r.to_a
  end

  def test_case_a_scalar_full_reduction_returns_scalar_or_nil
    a = CArray.float64(5).seq!(0, 1)
    # 1-D self -> full reduction, returns Ruby Integer
    assert_kind_of Integer, a.find_value_index_ki(3.0, 0)
    assert_nil               a.find_value_index_ki(99.0, 0)
  end

  # ----------------------------------------------------------------
  # rev5: 2-D self + 1-D val は無条件 A2 shared (= §3.1 統一 rule preserve)
  # base_shape の偶然一致では A2.5 に flip しない (= rev4 から priority flip)
  # ----------------------------------------------------------------

  def test_2d_self_1d_val_shared
    # self [3, 4] axis 1, val 1-D [3] -> A2 shared M=3, result [3, 3]
    a = CArray.float64(3, 4).seq!(0, 1)
    val = CArray.float64(3)
    val[0] = 1.0; val[1] = 5.0; val[2] = 9.0
    r = a.find_value_index_ki(val, 1)
    assert_equal [3, 3], r.dim
  end

  def test_2d_self_1d_val_axis_0
    # self [3, 4] axis 0, val 1-D [4] -> A2 shared M=4, result [4, 4]
    a = CArray.float64(3, 4).seq!(0, 1)
    val = CArray.float64(4)
    val[0] = 0.0; val[1] = 5.0; val[2] = 10.0; val[3] = 11.0
    r = a.find_value_index_ki(val, 0)
    assert_equal [4, 4], r.dim
  end

  def test_2d_per_fiber_scalar_via_reshape
    # rev5: per-fiber scalar use case (2-D self) は val.reshape(N, 1) で
    # A3 with M=1 に誘導
    a = CArray.float64(3, 4).seq!(0, 1)
    val_pf = CArray.float64(3, 1)
    val_pf[0, 0] = 1.0; val_pf[1, 0] = 5.0; val_pf[2, 0] = 9.0
    r = a.find_value_index_ki(val_pf, 1)
    assert_equal [3, 1], r.dim
    assert_equal [[1], [1], [1]], r.to_a
  end

  # ----------------------------------------------------------------
  # rev4 strict: size-1 broadcast removed -> raise
  # (= PROPOSAL_LINEAR_INTERP_PER_FIBER_MATCHED rev4 R4)
  # ----------------------------------------------------------------

  def test_case_c_general_broadcast_now_raises
    a = CArray.float64(3, 4, 5).seq!(0, 1)
    val = CArray.float64(1, 4)
    4.times { |j| val[0, j] = (j * 5).to_f }
    # base_shape = (3, 4), val = (1, 4) -> rev4 では size-1 broadcast 廃止
    # -> R4 reject (implicit broadcast 全 surface reject)
    assert_raise(ArgumentError) do
      a.find_value_index_ki(val, 2)
    end
  end

  # ----------------------------------------------------------------
  # Case B: val.shape doesn't broadcast -> append
  # ----------------------------------------------------------------

  def test_case_b_append_query_axis
    a = CArray.float64(3, 4).seq!(0, 1)
    # a[0]=[0,1,2,3], a[1]=[4,5,6,7], a[2]=[8,9,10,11]
    val = CArray.float64(5).seq!(0, 1)   # [0, 1, 2, 3, 4]
    # base_shape = (3,), val = (5,) -- can't broadcast (3 vs 5)
    # -> output = (3, 5), per (i, k) search a[i, :] for val[k]
    r = a.find_value_index_ki(val, 1)
    assert_equal [3, 5], r.dim
    # i=0: a[0]=[0,1,2,3], val=[0,1,2,3,4]
    #   k=0: 0 -> idx 0; k=1: 1 -> 1; k=2: 2 -> 2; k=3: 3 -> 3; k=4: 4 -> no -> -1
    assert_equal [0, 1, 2, 3, UNDEF], r[0, nil].to_a
    # i=1: a[1]=[4,5,6,7], val=[0,1,2,3,4]
    #   k=0..3 no; k=4: 4 -> idx 0
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF, 0], r[1, nil].to_a
    # i=2: a[2]=[8,9,10,11], no matches
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF, UNDEF], r[2, nil].to_a
  end

  def test_case_b_multi_d_val_now_raises
    # rev4 strict: outer product fallback 廃止。self [3, 4] axis 1 (= base [3])、
    # val [2, 2] は base != val、self.ndim==2 だが val.ndim==2 で A3 候補に
    # 突入 → 非 target 軸 dim[0]=2 != self.dim[0]=3 → R3 reject
    a = CArray.float64(3, 4).seq!(0, 1)
    val = CArray.float64(2, 2)
    val[0, 0] = 0.0;  val[0, 1] = 5.0
    val[1, 0] = 10.0; val[1, 1] = 99.0
    assert_raise(ArgumentError) do
      a.find_value_index_ki(val, 1)
    end
  end

  # ----------------------------------------------------------------
  # Vectorized 1-D: base_ndim = 0, val is 1-D
  # ----------------------------------------------------------------

  def test_vectorized_1d_curve_n_queries
    a = CArray.float64(5).seq!(0, 1)   # [0, 1, 2, 3, 4]
    val = CArray.float64(3).seq!(0, 2)  # [0, 2, 4]
    # base_ndim = 0, val.ndim = 1 -> broadcast OK -> output = (3,)
    r = a.find_value_index_ki(val, 0)
    assert_equal [3],       r.dim
    assert_equal [0, 2, 4], r.to_a
  end

  # ----------------------------------------------------------------
  # data_type cast: val data_type != self data_type
  # ----------------------------------------------------------------

  def test_data_type_cast_int_val_on_float_self
    a = CArray.float64(5).seq!(0, 1)
    val = CArray.int32(3).seq!(1, 1)   # [1, 2, 3]
    r = a.find_value_index_ki(val, 0)
    assert_equal [3],       r.dim
    assert_equal [1, 2, 3], r.to_a
  end

  def test_data_type_cast_float_val_on_int_self
    a = CArray.int32(5).seq!(0, 1)
    val = CArray.float64(3).seq!(2.0, 1.0)  # [2.0, 3.0, 4.0] -> cast to int32 [2,3,4]
    r = a.find_value_index_ki(val, 0)
    assert_equal [3],       r.dim
    assert_equal [2, 3, 4], r.to_a
  end

  # ----------------------------------------------------------------
  # mask global raise (mask_self: :raise)
  # ----------------------------------------------------------------

  def test_mask_self_raise_case_a
    a = CArray.float64(5).seq!(0, 1)
    a.mask = [0, 0, 1, 0, 0]
    assert_raise(RuntimeError) do
      a.find_value_index_ki(2.0, 0)
    end
  end

  def test_mask_self_raise_case_b_c
    a = CArray.float64(3, 4).seq!(0, 1)
    a.mask = 0
    a[0, 0] = UNDEF
    val = CArray.float64(3).seq!(0, 1)
    assert_raise(RuntimeError) do
      a.find_value_index_ki(val, 1)
    end
  end

  # ----------------------------------------------------------------
  # axis validation
  # ----------------------------------------------------------------

  def test_negative_axis
    a = CArray.float64(3, 4).seq!(0, 1)
    # axis=-1 should be normalized to axis=1
    r1 = a.find_value_index_ki(6.0, -1)
    r2 = a.find_value_index_ki(6.0, 1)
    assert_equal r1.to_a, r2.to_a
  end

  def test_axis_out_of_range
    a = CArray.float64(3, 4).seq!(0, 1)
    assert_raise(ArgumentError) do
      a.find_value_index_ki(0.0, 2)
    end
    assert_raise(ArgumentError) do
      a.find_value_index_ki(0.0, -3)
    end
  end

  # ----------------------------------------------------------------
  # CScalar val behavior (1-D shape [1] under CScalar, not actually 0-D)
  # ----------------------------------------------------------------

  def test_cscalar_val_treated_as_scalar
    # rev4 strict: CScalar (= elements==1) は A1 scalar 路に流れる。
    # 1-D self + scalar val -> Case A 完全 reduction -> Ruby Integer 戻り
    # (= test_case_a_scalar_full_reduction_returns_scalar_or_nil と同 path)
    a = CArray.float64(5).seq!(0, 1)
    cs = CScalar.float64
    cs[0] = 2.0
    r = a.find_value_index_ki(cs, 0)
    assert_kind_of Integer, r
    assert_equal 2, r
  end

  # ----------------------------------------------------------------
  # case A regression preserved after case B/C landing
  # ----------------------------------------------------------------

  def test_case_a_regression_after_case_bc_landing
    a = CArray.float64(5).seq!(0, 1)
    assert_equal 2,    a.find_value_index_ki(2.0, 0)
    assert_nil          a.find_value_index_ki(99.0, 0)
    b = CArray.float64(3, 4).seq!(0, 1)
    assert_equal [UNDEF, UNDEF, 1, UNDEF], b.find_value_index_ki(6.0, 0).to_a
  end
end
