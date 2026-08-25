# frozen_string_literal: true
#
# spec_ai/test_search_nearest_ki.rb
#
# S.4: search_nearest_ki -- per-slice nearest-value search.
# Tests:
#   - 1-D parity with legacy CArray#search_nearest
#   - axis化 (per-slice nearest)
#   - mask_self: :skip (= masked cells excluded from distance comparison)
#   - NaN query + all-NaN slab + all-masked slab edge cases
#   - case A / C / B (CArray val)
#   - data_type coverage

require "test/unit"
require_relative "../../lib/carray"

class TestSearchNearestKi < Test::Unit::TestCase
  ALL_NUMERIC = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
                   float32 float64]

  # ----------------------------------------------------------------
  # 1-D parity with legacy
  # ----------------------------------------------------------------

  def test_1d_parity_float
    a = CArray.float64(10).seq!(0.0, 1.0)
    [5.3, 5.7, 0.0, 9.0, -99.0, 99.0].each do |v|
      assert_equal a.search_nearest(v), a.search_nearest_ki(v, 0),
                   "v=#{v}"
    end
  end

  def test_1d_parity_int
    ALL_NUMERIC.reject { |d| d.to_s.start_with?("float") }.each do |data_type|
      a = CArray.send(data_type, 10).seq!(0, 1)
      [0, 5, 9].each do |v|
        assert_equal a.search_nearest(v), a.search_nearest_ki(v, 0),
                     "data_type=#{data_type} v=#{v}"
      end
    end
  end

  def test_1d_returns_scalar_or_nil
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_kind_of Integer, a.search_nearest_ki(5.3, 0)
    # All-masked slab gives nil
    a.mask = 1
    assert_nil a.search_nearest_ki(5.3, 0)
  end

  # ----------------------------------------------------------------
  # 2-D / 3-D axis化
  # ----------------------------------------------------------------

  def test_2d_axis_1_per_row
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    # row 0 = [0,1,2,3], nearest to 11.4 -> 3 (= dist 8.4)
    # row 1 = [10,11,12,13], nearest to 11.4 -> 11 (= dist 0.4)
    # row 2 = [20,21,22,23], nearest to 11.4 -> 20 (= dist 8.6)
    r = c.search_nearest_ki(11.4, 1)
    assert_equal [3],         r.dim
    assert_equal [3, 1, 0],   r.to_a
  end

  def test_2d_axis_0_per_column
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    # col 0 = [0, 10, 20], col 1 = [1, 11, 21], col 2 = [2, 12, 22], col 3 = [3, 13, 23]
    # nearest to 9.0 per col:
    #   col 0: [0,10,20] -> 10 (dist 1) at row 1
    #   col 1: [1,11,21] -> 11 (dist 2) at row 1
    #   col 2: [2,12,22] -> 12 (dist 3) at row 1; or 2 (dist 7)? 12 wins
    #   col 3: [3,13,23] -> 13 (dist 4) at row 1
    r = c.search_nearest_ki(9.0, 0)
    assert_equal [4],          r.dim
    assert_equal [1, 1, 1, 1], r.to_a
  end

  # ----------------------------------------------------------------
  # mask skip (mask_self: :skip)
  # ----------------------------------------------------------------

  def test_mask_skip_excludes_cell
    # a = [0, 1, 2, 3, 4]; mask index 2 (= 2.0).  nearest to 2.0:
    # without mask: 2 (dist 0).  with mask: dist 1.0 at index 1 OR 3,
    # first wins so index 1.
    a = CArray.float64(5).seq!(0.0, 1.0)
    a.mask = [0, 0, 1, 0, 0]
    assert_equal 1, a.search_nearest_ki(2.0, 0)
  end

  def test_all_masked_slab_returns_nil
    a = CArray.float64(5).seq!(0.0, 1.0)
    a.mask = 1
    assert_nil a.search_nearest_ki(2.0, 0)
  end

  def test_mask_skip_2d
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    # Mask row 1 fully.  axis=1 nearest to 11.4 per row:
    #   row 0: [0,1,2,3] -> 3
    #   row 1: all masked -> no nearest -> UNDEF (S1)
    #   row 2: [20,21,22,23] -> 20 = index 0
    c.mask = 0
    4.times { |j| c[1, j] = UNDEF }
    r = c.search_nearest_ki(11.4, 1)
    assert_equal [3, UNDEF, 0], r.to_a
  end

  # ----------------------------------------------------------------
  # NaN handling
  # ----------------------------------------------------------------

  def test_nan_query_returns_nil
    a = CArray.float64(5).seq!(0.0, 1.0)
    assert_nil a.search_nearest_ki(Float::NAN, 0)
  end

  def test_nan_cells_skipped
    # Slab with NaN cells: NaN dist is never < best_dist so silently skipped
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = Float::NAN; a[2] = 3.0; a[3] = Float::NAN; a[4] = 5.0
    # nearest to 3.5: distances [2.5, NaN, 0.5, NaN, 1.5] -> idx 2
    assert_equal 2, a.search_nearest_ki(3.5, 0)
  end

  # ----------------------------------------------------------------
  # case C / case B (CArray val)
  # ----------------------------------------------------------------

  def test_case_c_exact
    # rev5: self [3, 4] axis 1, val 1-D [3] -> A2 shared M=3, result [3, 3]
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(3)
    val[0] = 1.4; val[1] = 11.4; val[2] = 21.4
    r = c.search_nearest_ki(val, 1)
    assert_equal [3, 3], r.dim
  end

  def test_case_b_append
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(2)
    val[0] = 1.4; val[1] = 99.0
    r = c.search_nearest_ki(val, 1)
    assert_equal [3, 2], r.dim
    # row 0 = [0,1,2,3]: nearest to 1.4 -> 1; to 99 -> 3
    # row 1 = [10,11,12,13]: nearest to 1.4 -> 0 (= 10, dist 8.6); to 99 -> 3 (= 13)
    # row 2 = [20,21,22,23]: nearest to 1.4 -> 0 (= 20, dist 18.6); to 99 -> 3 (= 23)
    assert_equal [1, 3], r[0, nil].to_a
    assert_equal [0, 3], r[1, nil].to_a
    assert_equal [0, 3], r[2, nil].to_a
  end

  # ----------------------------------------------------------------
  # axis validation
  # ----------------------------------------------------------------

  def test_negative_axis
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    assert_equal c.search_nearest_ki(11.4, 1).to_a,
                 c.search_nearest_ki(11.4, -1).to_a
  end

  def test_axis_out_of_range
    c = CArray.float64(3, 4).seq!(0, 1)
    assert_raise(ArgumentError) { c.search_nearest_ki(0.0, 2) }
    assert_raise(ArgumentError) { c.search_nearest_ki(0.0, -3) }
  end

  # ----------------------------------------------------------------
  # arity (= 2 positional, no eps)
  # ----------------------------------------------------------------

  def test_arity_exactly_2
    a = CArray.float64(5).seq!(0.0, 1.0)
    assert_kind_of Integer, a.search_nearest_ki(2.0, 0)
    assert_raise(ArgumentError) { a.search_nearest_ki(2.0) }
    assert_raise(ArgumentError) { a.search_nearest_ki(2.0, 0, 0.001) }
  end
end
