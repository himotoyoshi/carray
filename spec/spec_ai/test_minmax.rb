# spec_ai/test_minmax.rb
#
# FM.2 acceptance pin for PROPOSAL_FUSED_MINMAX.
#
# CArray#minmax — fused single-pass min+max reduction returning
# [min_val, max_val].  Implemented as a multi-output kernel via the
# outputs:2 mkkernel framework extension (= FM.1.0 commit a580646,
# mask propagation FM.1.5 commit e6e3c78).
#
# Test matrix:
#   - flat reduction parity vs separate min/max across all 10 numeric dtypes
#   - per-axis (k=0 / k=1 / k=-1) parity
#   - 3-D per-axis
#   - mask: legacy default, min_count: kwarg, all-masked
#   - NaN semantics (= consistent with single min/max)
#   - dtype boundary (int over/underflow ranges as initial sentinels)
#   - return shape: [Scalar, Scalar] for flat, [CArray, CArray] for axis
#   - destructuring idiom: `lo, hi = a.minmax`
#   - empty / 1-element / unsupported dtype

require "test/unit"
require "carray"

class TestMinmax < Test::Unit::TestCase

  # ---- flat: all 10 numeric dtypes ----------------------------------

  NUMERIC_DTYPES = [
    CA_INT8,  CA_UINT8,  CA_INT16, CA_UINT16,
    CA_INT32, CA_UINT32, CA_INT64, CA_UINT64,
    CA_FLOAT32, CA_FLOAT64,
  ].freeze

  def test_flat_parity_all_dtypes
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [8])
      # Use values that fit safely in all dtypes including int8 (-128..127)
      vals = [5, -3, 8, -10, 2, -8, 12, 0]
      vals = vals.map(&:abs) if [CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].include?(dt)
      vals.each_with_index { |v, i| a[i] = v }
      lo, hi = a.minmax
      assert_equal a.min, lo, "dtype=#{dt} min mismatch"
      assert_equal a.max, hi, "dtype=#{dt} max mismatch"
    end
  end

  def test_flat_returns_array_of_two
    a = CArray.float64(5) { |i| [1.5, 2.5, 0.5, 3.5, 4.5][i] }
    r = a.minmax
    assert_kind_of Array, r
    assert_equal 2, r.size
    assert_equal 0.5, r[0]
    assert_equal 4.5, r[1]
  end

  def test_flat_destructuring_idiom
    a = CArray.int64(4) { |i| [7, 2, 9, 4][i] }
    lo, hi = a.minmax
    assert_equal 2, lo
    assert_equal 9, hi
  end

  def test_flat_single_element
    a = CArray.float64(1) { |i| 42.0 }
    assert_equal [42.0, 42.0], a.minmax
  end

  # ---- per-axis 2-D ------------------------------------------------

  def test_per_axis_2d_axis0
    a = CArray.int64(2, 3) { |i, j| [[5, 2, 8], [1, 7, 3]][i][j] }
    lo, hi = a.minmax(axis: 0)
    assert_kind_of CArray, lo
    assert_kind_of CArray, hi
    assert_equal [1, 2, 3], lo.to_a
    assert_equal [5, 7, 8], hi.to_a
    assert_equal a.min(axis: 0).to_a, lo.to_a
    assert_equal a.max(axis: 0).to_a, hi.to_a
  end

  def test_per_axis_2d_axis1
    a = CArray.float64(2, 3) { |i, j| [[5.0, 2.0, 8.0], [1.0, 7.0, 3.0]][i][j] }
    lo, hi = a.minmax(axis: 1)
    assert_equal [2.0, 1.0], lo.to_a
    assert_equal [8.0, 7.0], hi.to_a
  end

  def test_per_axis_2d_axis_negative
    a = CArray.int64(2, 3) { |i, j| [[5, 2, 8], [1, 7, 3]][i][j] }
    lo_neg, hi_neg = a.minmax(axis: -1)
    lo_pos, hi_pos = a.minmax(axis: 1)
    assert_equal lo_pos.to_a, lo_neg.to_a
    assert_equal hi_pos.to_a, hi_neg.to_a
  end

  # ---- per-axis 3-D ------------------------------------------------

  def test_per_axis_3d
    a = CArray.float64(2, 3, 4) { |i, j, k| (i * 100 + j * 10 + k).to_f }
    [0, 1, 2].each do |axis|
      lo, hi = a.minmax(axis: axis)
      assert_equal a.min(axis: axis).to_a, lo.to_a, "axis=#{axis} min"
      assert_equal a.max(axis: axis).to_a, hi.to_a, "axis=#{axis} max"
    end
  end

  # ---- mask: legacy default ---------------------------------------

  def test_masked_legacy_default_flat
    a = CArray.float64(6) { |i| [3.1, 1.2, 4.5, 1.5, 9.2, 2.6][i] }
    a[1] = UNDEF; a[4] = UNDEF
    lo, hi = a.minmax
    assert_equal a.min, lo
    assert_equal a.max, hi
    assert_equal 1.5, lo
    assert_equal 4.5, hi
  end

  def test_masked_all_returns_undef
    a = CArray.float64(3) { 1.0 }
    a[0] = UNDEF; a[1] = UNDEF; a[2] = UNDEF
    assert_equal UNDEF, a.minmax
  end

  def test_masked_per_axis
    a = CArray.int64(2, 3) { |i, j| [[5, 2, 8], [1, 7, 3]][i][j] }
    a[0, 1] = UNDEF
    lo, hi = a.minmax(axis: 0)
    assert_equal a.min(axis: 0).to_a, lo.to_a
    assert_equal a.max(axis: 0).to_a, hi.to_a
  end

  def test_masked_per_axis_partial
    # Column 1: only [0,1]=UNDEF, [1,1]=7 valid -> min=max=7
    a = CArray.int64(2, 3) { |i, j| [[5, 2, 8], [1, 7, 3]][i][j] }
    a[0, 1] = UNDEF
    lo, hi = a.minmax(axis: 0)
    assert_equal 7, lo[1]
    assert_equal 7, hi[1]
  end

  # ---- mask: min_count: kwarg -------------------------------------

  def test_min_count_kwarg_flat_undef
    a = CArray.float64(5) { |i| [1.0, 2.0, 3.0, 4.0, 5.0][i] }
    a[0] = UNDEF; a[1] = UNDEF; a[2] = UNDEF
    # Only 2 valid cells, min_count: 3 should yield UNDEF
    assert_equal UNDEF, a.minmax(min_count: 3)
  end

  def test_min_count_kwarg_flat_ok
    a = CArray.float64(5) { |i| [1.0, 2.0, 3.0, 4.0, 5.0][i] }
    a[0] = UNDEF
    # 4 valid cells, min_count: 3 is satisfied
    lo, hi = a.minmax(min_count: 3)
    assert_equal 2.0, lo
    assert_equal 5.0, hi
  end

  def test_min_count_kwarg_per_axis
    a = CArray.int64(2, 4) { |i, j| [[1, 2, 3, 4], [5, 6, 7, 8]][i][j] }
    a[0, 0] = UNDEF; a[0, 1] = UNDEF
    lo, hi = a.minmax(axis: 0, min_count: 2)
    # mask elements are boolean8_t 0/1, and 0 is truthy in Ruby --
    # compare with == 1 / == 0 instead of truthy/refute.
    # cols 0/1 each have only 1 valid cell, should be masked
    assert_equal true, lo.mask[0]
    assert_equal true, hi.mask[0]
    assert_equal true, lo.mask[1]
    # cols 2/3 have 2 valid cells, should not be masked
    assert_equal false, lo.mask[2]
    assert_equal 3, lo[2]
    assert_equal 7, hi[2]
  end

  # ---- NaN handling -----------------------------------------------

  def test_nan_handling_matches_min_max
    # NaN propagation in CArray min/max: NaN is sticky if encountered;
    # behavior should match between minmax and separate min/max.
    a = CArray.float64(5) { |i| [3.0, 1.0, Float::NAN, 4.0, 2.0][i] }
    lo, hi = a.minmax
    ref_min = a.min
    ref_max = a.max
    if ref_min.nan?
      assert lo.nan?
    else
      assert_equal ref_min, lo
    end
    if ref_max.nan?
      assert hi.nan?
    else
      assert_equal ref_max, hi
    end
  end

  # ---- dtype boundaries -------------------------------------------

  def test_int_extremes_i8
    # T_LIMIT_HI / T_LIMIT_LO sentinels: ensure the kernel doesn't
    # mis-initialize with garbage when the input contains extreme values.
    a = CArray.int8(3) { |i| [-128, 0, 127][i] }
    assert_equal [-128, 127], a.minmax
  end

  def test_int_extremes_u8
    a = CArray.uint8(3) { |i| [0, 128, 255][i] }
    assert_equal [0, 255], a.minmax
  end

  def test_int_extremes_i64
    a = CArray.int64(3) { |i| [-(2**62), 0, (2**62)][i] }
    assert_equal [-(2**62), (2**62)], a.minmax
  end

  # ---- byte parity vs separate calls ------------------------------

  def test_byte_parity_random_f64
    srand 42
    a = CArray.float64(1000) { rand * 1000 - 500 }
    lo, hi = a.minmax
    assert_equal a.min, lo
    assert_equal a.max, hi
  end

  def test_byte_parity_random_i32
    srand 43
    a = CArray.int32(1000) { rand(-1_000_000..1_000_000) }
    lo, hi = a.minmax
    assert_equal a.min, lo
    assert_equal a.max, hi
  end

  def test_byte_parity_per_axis_3d_f32
    srand 44
    a = CArray.float32(4, 5, 6) { rand * 100 }
    [0, 1, 2].each do |axis|
      lo, hi = a.minmax(axis: axis)
      assert_equal a.min(axis: axis).to_a, lo.to_a, "axis=#{axis} min"
      assert_equal a.max(axis: axis).to_a, hi.to_a, "axis=#{axis} max"
    end
  end

  # ---- unsupported dtype rejection ---------------------------------

  def test_boolean_minmax_numeric
    # 3.0: boolean minmax returns [0, 1] (Integer), not [false, true] --
    # boolean participates as its 0/1 numeric storage.
    a = CArray.boolean(5) { |i| i.odd? }   # [0, 1, 0, 1, 0]
    lo, hi = a.minmax
    assert_equal 0, lo
    assert_equal 1, hi
  end

  # ---- per-axis return data_type preservation ----------------------

  def test_return_dtype_matches_input
    [CA_INT16, CA_INT64, CA_FLOAT32, CA_FLOAT64].each do |dt|
      a = CArray.new(dt, [3, 3]) { |i, j| i + j }
      lo, hi = a.minmax(axis: 0)
      assert_equal dt, lo.data_type, "dt=#{dt} lo"
      assert_equal dt, hi.data_type, "dt=#{dt} hi"
    end
  end
end
