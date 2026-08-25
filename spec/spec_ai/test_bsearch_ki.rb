# frozen_string_literal: true
#
# spec_ai/test_bsearch_ki.rb
#
# S.2: bsearch_ki -- production binary search kernel via mkkernel search
# form.  Tests:
#   - 1-D parity with legacy CArray#bsearch
#   - axis化 (= per-slice bsearch along arbitrary axis)
#   - case A (scalar) / case C (val == base) / case B (append)
#   - NaN handling: query NaN -> nil; slab with NaN-end still searches
#   - mask global raise
#   - all 10 numeric data_types

require "test/unit"
require_relative "../../lib/carray"

class TestBsearchKi < Test::Unit::TestCase
  ALL_NUMERIC = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
                   float32 float64]

  # ----------------------------------------------------------------
  # 1-D parity with legacy bsearch
  # ----------------------------------------------------------------

  def test_1d_parity_with_legacy_bsearch
    ALL_NUMERIC.each do |data_type|
      a = CArray.send(data_type, 20).seq!(0, 1)   # sorted [0..19]
      [0, 5, 10, 19].each do |v|
        assert_equal a.bsearch(v), a.bsearch_ki(v, 0),
                     "data_type=#{data_type} match v=#{v}"
      end
      assert_equal a.bsearch(99), a.bsearch_ki(99, 0),
                   "data_type=#{data_type} no-match"
    end
  end

  def test_1d_returns_scalar_integer_or_nil
    a = CArray.float64(10).seq!(0, 1)
    assert_kind_of Integer, a.bsearch_ki(5.0, 0)
    assert_nil               a.bsearch_ki(99.0, 0)
  end

  # ----------------------------------------------------------------
  # axis化: 2-D / 3-D
  # ----------------------------------------------------------------

  def test_2d_axis_1_per_row
    # b[i, j] = i*10 + j, each row sorted ascending
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i*10 + j).to_f } }
    # Search val=12 per row: only row 1 has it at col 2
    r = b.bsearch_ki(12.0, 1)
    assert_equal [3],          r.dim
    # S1 (PROPOSAL_SEARCH_SEMANTICS_UNIFY): per-fiber no-match -> UNDEF
    assert_equal [UNDEF, 2, UNDEF], r.to_a
    assert_equal [true, false, true],         r.is_masked.to_a
  end

  def test_2d_axis_0_per_column
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i*10 + j).to_f } }
    # Per column, axis=0 values: col j = [j, 10+j, 20+j] -- sorted
    # Search val=10: col 0 = [0, 10, 20], match at row 1
    r = b.bsearch_ki(10.0, 0)
    assert_equal [4],            r.dim
    assert_equal [1, UNDEF, UNDEF, UNDEF], r.to_a
  end

  def test_3d_middle_axis
    # a[i, j, k] = i*12 + j*4 + k -- not sorted along axis 1 generically
    # Build with axis=1 sorted: a[i, j, k] = i*100 + j + k*5
    a = CArray.float64(2, 3, 4)
    2.times do |i|
      3.times do |j|
        4.times do |k|
          a[i, j, k] = (i*100 + j + k*5).to_f
        end
      end
    end
    # For each (i, k), a[i, :, k] = [i*100 + 0 + k*5, i*100 + 1 + k*5, i*100 + 2 + k*5]
    # = sorted ascending
    # Search val=101 in axis=1: at i=1, k=0, j=1 (= 100+1+0)
    r = a.bsearch_ki(101.0, 1)
    assert_equal [2, 4], r.dim
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF], r[0, nil].to_a
    assert_equal [1, UNDEF, UNDEF, UNDEF],     r[1, nil].to_a
  end

  # ----------------------------------------------------------------
  # case C: val == base shape
  # ----------------------------------------------------------------

  def test_case_c_exact
    # rev5: self [3, 4] axis 1, val 1-D [3] -> A2 shared M=3, result [3, 3]
    # (= rev4 では base_shape 一致で A2.5 [3]、rev5 priority flip で §3.1 統一
    # rule preserve. per-fiber scalar use case は val.reshape(3, 1) で A3 経由)
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i*10 + j).to_f } }
    val = CArray.float64(3)
    val[0] = 2.0; val[1] = 12.0; val[2] = 23.0
    r = b.bsearch_ki(val, 1)
    assert_equal [3, 3], r.dim   # A2 shared (rev5)
  end

  # ----------------------------------------------------------------
  # case B: val.shape doesn't broadcast -> append
  # ----------------------------------------------------------------

  def test_case_b_append
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i*10 + j).to_f } }
    val = CArray.float64(5)
    val[0] = 0.0; val[1] = 5.0; val[2] = 12.0; val[3] = 22.0; val[4] = 99.0
    r = b.bsearch_ki(val, 1)
    assert_equal [3, 5], r.dim
    # S1: no-match cells -> UNDEF (case B array query)
    # row 0 = [0,1,2,3], search val [0,5,12,22,99] -> [0,x,x,x,x]
    assert_equal [0, UNDEF, UNDEF, UNDEF, UNDEF],  r[0, nil].to_a
    # row 1 = [10,11,12,13], search [0,5,12,22,99] -> [x,x,2,x,x]
    assert_equal [UNDEF, UNDEF, 2, UNDEF, UNDEF],  r[1, nil].to_a
    # row 2 = [20,21,22,23], search [0,5,12,22,99] -> [x,x,x,2,x]
    assert_equal [UNDEF, UNDEF, UNDEF, 2, UNDEF],  r[2, nil].to_a
  end

  # ----------------------------------------------------------------
  # NaN handling
  # ----------------------------------------------------------------

  def test_nan_query_returns_nil_or_undef
    a = CArray.float64(5).seq!(0, 1)
    nan = Float::NAN
    assert_nil a.bsearch_ki(nan, 0)
  end

  def test_nan_at_slab_end_still_searchable
    # NaN sorts to end (legacy qcmp_f_type semantic)
    fb = CArray.float64(5)
    fb[0] = 1.0; fb[1] = 2.0; fb[2] = 3.0; fb[3] = Float::NAN; fb[4] = Float::NAN
    assert_equal 0, fb.bsearch_ki(1.0, 0)
    assert_equal 1, fb.bsearch_ki(2.0, 0)
    assert_equal 2, fb.bsearch_ki(3.0, 0)
    assert_nil      fb.bsearch_ki(4.0, 0)   # not present
  end

  # ----------------------------------------------------------------
  # mask global raise (mask_self: :raise)
  # ----------------------------------------------------------------

  def test_mask_global_raise
    a = CArray.float64(5).seq!(0, 1)
    a.mask = [0, 0, 1, 0, 0]
    assert_raise(RuntimeError) do
      a.bsearch_ki(2.0, 0)
    end
  end

  # ----------------------------------------------------------------
  # axis validation
  # ----------------------------------------------------------------

  def test_negative_axis
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i*10 + j).to_f } }
    r1 = b.bsearch_ki(12.0, -1)
    r2 = b.bsearch_ki(12.0, 1)
    assert_equal r1.to_a, r2.to_a
  end

  def test_axis_out_of_range
    b = CArray.float64(3, 4).seq!(0, 1)
    assert_raise(ArgumentError) { b.bsearch_ki(0.0, 2) }
    assert_raise(ArgumentError) { b.bsearch_ki(0.0, -3) }
  end

  # ----------------------------------------------------------------
  # data_type cast
  # ----------------------------------------------------------------

  def test_data_type_cast_int_val_on_float_self
    a = CArray.float64(10).seq!(0, 1)
    val = CArray.int32(3).seq!(1, 1)   # [1, 2, 3]
    r = a.bsearch_ki(val, 0)
    assert_equal [3],       r.dim
    assert_equal [1, 2, 3], r.to_a
  end
end
