# frozen_string_literal: true
#
# spec_ai/test_search_ki.rb
#
# S.3: search_ki -- linear-scan search with optional eps tolerance.
# Tests:
#   - 1-D parity with legacy CArray#search (= for cases where legacy and new behavior agree)
#   - axis化 (per-slice search)
#   - eps positional 3rd arg (= float fuzzy tolerance)
#   - mask_self: :skip (per-slice mask skip)
#   - case A / case C / case B / vectorized 1-D
#   - data_type coverage (int vs float per-data_type body)

require "test/unit"
require_relative "../../lib/carray"

class TestSearchKi < Test::Unit::TestCase
  ALL_NUMERIC = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
                   float32 float64]

  # ----------------------------------------------------------------
  # 1-D parity with legacy search (where semantics align)
  # ----------------------------------------------------------------

  def test_1d_parity_with_legacy_search_float
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal a.search(5.0), a.search_ki(5.0, 0)
    assert_equal a.search(0.0), a.search_ki(0.0, 0)
    assert_equal a.search(9.0), a.search_ki(9.0, 0)
    assert_equal a.search(99.0), a.search_ki(99.0, 0)
  end

  def test_1d_parity_with_legacy_search_int
    ALL_NUMERIC.reject { |d| d.to_s.start_with?("float") }.each do |data_type|
      a = CArray.send(data_type, 10).seq!(0, 1)
      [0, 5, 9].each do |v|
        assert_equal a.search(v), a.search_ki(v, 0), "data_type=#{data_type} v=#{v}"
      end
      assert_equal a.search(99), a.search_ki(99, 0), "data_type=#{data_type} no-match"
    end
  end

  # ----------------------------------------------------------------
  # eps tolerance (float only)
  # ----------------------------------------------------------------

  def test_eps_finds_close_match
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_nil           a.search_ki(5.0001, 0)        # exact: no match
    assert_equal 5,      a.search_ki(5.0001, 0, 0.001)  # eps 0.001 finds 5.0
  end

  def test_eps_zero_means_exact_match
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal 5,      a.search_ki(5.0, 0, 0.0)
    assert_nil           a.search_ki(5.0001, 0, 0.0)
  end

  def test_eps_default_uses_dbl_epsilon_for_f64
    # default eps = DBL_EPSILON * |val|, very tight tolerance.
    # 5.0 should match itself; 5.0 + 1e-10 should NOT (= 1e-10 > DBL_EPSILON*5).
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal 5, a.search_ki(5.0, 0)
    assert_nil      a.search_ki(5.0 + 1e-10, 0)
  end

  def test_eps_ignored_for_int_data_types
    # int data_types: exact match only, eps argument is silently ignored.
    a = CArray.int32(10).seq!(0, 1)
    assert_equal 5, a.search_ki(5, 0, 99)    # eps doesn't help
    assert_nil      a.search_ki(99, 0, 99)   # still no match
  end

  # ----------------------------------------------------------------
  # axis化
  # ----------------------------------------------------------------

  def test_2d_axis_1
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    # search val=11.0 per row: only row 1 has it at col 1
    r = b.search_ki(11.0, 1)
    assert_equal [3],          r.dim
    assert_equal [UNDEF, 1, UNDEF],  r.to_a   # S1: no-match -> UNDEF
  end

  def test_2d_axis_0
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    # col 0 = [0, 10, 20]; search 10 → row 1
    r = b.search_ki(10.0, 0)
    assert_equal [4],             r.dim
    assert_equal [1, UNDEF, UNDEF, UNDEF], r.to_a
  end

  def test_1d_full_reduction_returns_scalar
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_kind_of Integer, a.search_ki(5.0, 0)
    assert_nil               a.search_ki(99.0, 0)
  end

  # ----------------------------------------------------------------
  # case C / case B (CArray val)
  # ----------------------------------------------------------------

  def test_case_c_exact
    # rev5: self [3, 4] axis 1, val 1-D [3] -> A2 shared M=3, result [3, 3]
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(3)
    val[0] = 1.0; val[1] = 11.0; val[2] = 21.0
    r = b.search_ki(val, 1)
    assert_equal [3, 3], r.dim
  end

  def test_case_b_append
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(5)
    val[0] = 0.0; val[1] = 5.0; val[2] = 11.0; val[3] = 22.0; val[4] = 99.0
    r = b.search_ki(val, 1)
    assert_equal [3, 5], r.dim
    # row 0 = [0,1,2,3], search [0,5,11,22,99] -> [0,-1,-1,-1,-1]
    assert_equal [0, UNDEF, UNDEF, UNDEF, UNDEF],  r[0, nil].to_a
    # row 1 = [10,11,12,13], search [0,5,11,22,99] -> [-1,-1,1,-1,-1]
    assert_equal [UNDEF, UNDEF, 1, UNDEF, UNDEF],  r[1, nil].to_a
    # row 2 = [20,21,22,23], search [0,5,11,22,99] -> [-1,-1,-1,2,-1]
    assert_equal [UNDEF, UNDEF, UNDEF, 2, UNDEF],  r[2, nil].to_a
  end

  # ----------------------------------------------------------------
  # mask_self: :skip (per-slice mask skip)
  # ----------------------------------------------------------------

  def test_mask_skip_skips_masked_cells
    a = CArray.float64(10).seq!(0.0, 1.0)
    a.mask = [0, 0, 1, 0, 0, 0, 0, 0, 0, 0]   # cell 2 masked
    # Search 2.0: would match cell 2 but it's masked -> skip, no match
    assert_nil       a.search_ki(2.0, 0)
    # Search 3.0: cell 3 unmasked, found
    assert_equal 3,  a.search_ki(3.0, 0)
  end

  def test_mask_skip_2d
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    # Mask b[1, 1] (= 11.0)
    b.mask = 0
    b[1, 1] = UNDEF
    # axis=1 per-row search 11.0: row 1's match cell is masked -> no match -> UNDEF
    r = b.search_ki(11.0, 1)
    assert_equal [UNDEF, UNDEF, UNDEF], r.to_a
  end

  # ----------------------------------------------------------------
  # NaN
  # ----------------------------------------------------------------

  def test_nan_query_returns_nil
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_nil a.search_ki(Float::NAN, 0)
  end

  # ----------------------------------------------------------------
  # axis validation
  # ----------------------------------------------------------------

  def test_negative_axis
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    assert_equal b.search_ki(11.0, 1).to_a, b.search_ki(11.0, -1).to_a
  end

  def test_axis_out_of_range
    b = CArray.float64(3, 4).seq!(0, 1)
    assert_raise(ArgumentError) { b.search_ki(0.0, 2) }
    assert_raise(ArgumentError) { b.search_ki(0.0, -3) }
  end

  # ----------------------------------------------------------------
  # arity (= variadic accepts 2 or 3 args)
  # ----------------------------------------------------------------

  def test_arity_2_or_3
    a = CArray.float64(5).seq!(0.0, 1.0)
    assert_equal 2, a.search_ki(2.0, 0)
    assert_equal 2, a.search_ki(2.0, 0, 0.001)
    assert_raise(ArgumentError) { a.search_ki(2.0) }
    assert_raise(ArgumentError) { a.search_ki(2.0, 0, 0.001, :extra) }
  end

  # ----------------------------------------------------------------
  # data_type cast
  # ----------------------------------------------------------------

  def test_data_type_cast_int_val_on_float_self
    a = CArray.float64(10).seq!(0.0, 1.0)
    val = CArray.int32(3).seq!(1, 1)   # [1, 2, 3]
    r = a.search_ki(val, 0)
    assert_equal [1, 2, 3], r.to_a
  end
end
