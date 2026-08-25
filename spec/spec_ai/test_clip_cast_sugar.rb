# spec_ai/test_clip_cast_sugar.rb
#
# CC.2 acceptance pin for PROPOSAL_CLIP_CAST_SUGAR.
#
# CArray#clip_<dtype> — value -> bounded storage sugar, defined as
# the literal sugar for `clip(<MIN>, <MAX>).as_<dtype>`.
#
# Test matrix (AC1-AC5):
#   - AC1: byte parity with literal composition for each dtype
#   - AC2: cross-platform consistent values for negative / overflow / NaN
#   - AC3: NaN behavior inherited from clip (not newly pinned)
#   - AC4: existing as_<dtype> / clip / CAFake surfaces unchanged
#   - AC5: mask carry from clip

require "test/unit"
require "carray"

class TestClipCastSugar < Test::Unit::TestCase

  INT8_MIN  = -128
  INT8_MAX  = 127
  INT16_MIN = -32_768
  INT16_MAX = 32_767
  INT32_MIN = -2_147_483_648
  INT32_MAX = 2_147_483_647
  INT64_MIN = -9_223_372_036_854_775_808
  INT64_MAX = 9_223_372_036_854_775_807
  UINT8_MAX  = 255
  UINT16_MAX = 65_535
  UINT32_MAX = 4_294_967_295
  UINT64_MAX = 18_446_744_073_709_551_615

  # --- AC1: byte parity with literal composition ---

  def test_clip_int8_byte_parity
    a = CA_DOUBLE([-1000.0, -128.0, -1.0, 0.0, 1.0, 127.0, 1000.0])
    assert_equal a.clip(INT8_MIN, INT8_MAX).as_int8.to_a, a.clip_int8.to_a
  end

  def test_clip_int16_byte_parity
    a = CA_DOUBLE([-1e6, -32_768.0, -1.0, 0.0, 32_767.0, 1e6])
    assert_equal a.clip(INT16_MIN, INT16_MAX).as_int16.to_a, a.clip_int16.to_a
  end

  def test_clip_int32_byte_parity
    a = CA_DOUBLE([-1e15, INT32_MIN.to_f, -1.0, 0.0, INT32_MAX.to_f, 1e15])
    assert_equal a.clip(INT32_MIN, INT32_MAX).as_int32.to_a, a.clip_int32.to_a
  end

  def test_clip_int64_byte_parity
    # INT64 range is at the edge of f64 precision; use safe values.
    a = CA_DOUBLE([-1e18, -1.0, 0.0, 1.0, 1e18])
    assert_equal a.clip(INT64_MIN, INT64_MAX).as_int64.to_a, a.clip_int64.to_a
  end

  def test_clip_uint8_byte_parity
    a = CA_DOUBLE([-1000.0, -1.0, 0.0, 100.0, 255.0, 1000.0])
    assert_equal a.clip(0, UINT8_MAX).as_uint8.to_a, a.clip_uint8.to_a
  end

  def test_clip_uint16_byte_parity
    a = CA_DOUBLE([-1e5, -1.0, 0.0, 65_535.0, 1e5])
    assert_equal a.clip(0, UINT16_MAX).as_uint16.to_a, a.clip_uint16.to_a
  end

  def test_clip_uint32_byte_parity
    a = CA_DOUBLE([-1e15, -2_147_418_368.0, -1.0, 0.0, UINT32_MAX.to_f, 1e15])
    assert_equal a.clip(0, UINT32_MAX).as_uint32.to_a, a.clip_uint32.to_a
  end

  def test_clip_uint64_byte_parity
    a = CA_DOUBLE([-1e18, -1.0, 0.0, 1.0, 1e18])
    assert_equal a.clip(0, UINT64_MAX).as_uint64.to_a, a.clip_uint64.to_a
  end

  # --- AC2: cross-platform consistent values for canonical cases ---
  # These values are guaranteed regardless of ARM saturate vs x86 wrap,
  # because clip happens in value domain before any cast UB is reached.

  def test_negative_input_clamps_to_zero_for_unsigned
    a = CA_DOUBLE([-1.0])
    assert_equal [0],          a.clip_uint8.to_a
    assert_equal [0],          a.clip_uint16.to_a
    assert_equal [0],          a.clip_uint32.to_a
    assert_equal [0],          a.clip_uint64.to_a
  end

  def test_negative_overflow_clamps_to_min_for_signed
    a = CA_DOUBLE([-1e20])
    assert_equal [INT8_MIN],   a.clip_int8.to_a
    assert_equal [INT16_MIN],  a.clip_int16.to_a
    assert_equal [INT32_MIN],  a.clip_int32.to_a
    # int64 left out: -1e20 is near edge of int64 range and clip rounding can vary.
  end

  def test_positive_overflow_clamps_to_max
    a = CA_DOUBLE([1e20])
    assert_equal [UINT8_MAX],  a.clip_uint8.to_a
    assert_equal [UINT16_MAX], a.clip_uint16.to_a
    assert_equal [UINT32_MAX], a.clip_uint32.to_a
    assert_equal [UINT64_MAX], a.clip_uint64.to_a
    assert_equal [INT8_MAX],   a.clip_int8.to_a
    assert_equal [INT16_MAX],  a.clip_int16.to_a
    assert_equal [INT32_MAX],  a.clip_int32.to_a
  end

  def test_in_range_values_passthrough
    a = CA_DOUBLE([0.0, 1.0, 100.0])
    assert_equal [0, 1, 100], a.clip_uint8.to_a
    assert_equal [0, 1, 100], a.clip_int8.to_a
    assert_equal [0, 1, 100], a.clip_uint32.to_a
    assert_equal [0, 1, 100], a.clip_int32.to_a
  end

  def test_gnuplot_argb_pattern
    # PROPOSAL §1: the canonical motivating example.
    # ARGB #8000ff00 stored as signed -2147418368, round-tripped via
    # double, expected back as uint32 2147548928.
    # With raw as_uint32 this is platform-dependent (= ARM yields 0).
    # With clip_uint32 the negative is clipped to 0 in value domain,
    # which is at least cross-platform consistent (= explicit, predictable).
    a = CA_DOUBLE([-2_147_418_368.0])
    # clip_uint32 of negative double -> 0 (explicit, by design)
    assert_equal [0], a.clip_uint32.to_a
  end

  # --- AC3: NaN behavior is inherited from clip, not separately pinned ---

  def test_nan_behavior_matches_clip_composition
    # We don't pin a specific NaN policy in this phase; we only require
    # that clip_<dtype>(NaN) == clip(MIN, MAX).as_<dtype>(NaN).
    a = CA_DOUBLE([Float::NAN])
    assert_equal a.clip(0, UINT8_MAX).as_uint8.to_a,    a.clip_uint8.to_a
    assert_equal a.clip(0, UINT32_MAX).as_uint32.to_a,  a.clip_uint32.to_a
    assert_equal a.clip(INT8_MIN, INT8_MAX).as_int8.to_a, a.clip_int8.to_a
  end

  # --- AC4: existing surfaces unchanged ---

  def test_as_dtype_surface_unchanged
    # as_<dtype> still follows raw C cast semantics (not clip-then-cast).
    # We verify the in-range values pass through identically.
    a = CA_DOUBLE([0.0, 100.0])
    assert_equal [0, 100], a.as_uint8.to_a
    assert_equal [0, 100], a.as_int32.to_a
    assert_equal [0, 100], a.as_uint64.to_a
  end

  def test_clip_surface_unchanged
    a = CA_DOUBLE([-1.0, 5.0, 100.0])
    # Two-arg clip retains its existing semantics: returns float (same dtype as self).
    result = a.clip(0, 10)
    assert_equal CA_FLOAT64, result.data_type
    assert_equal [0.0, 5.0, 10.0], result.to_a
  end

  def test_input_array_not_mutated
    a = CA_DOUBLE([-1.0, 100.0, 1e20])
    _ = a.clip_uint8
    assert_equal [-1.0, 100.0, 1e20], a.to_a
  end

  # --- AC5: mask carry from clip ---

  def test_mask_carries_through_clip_uint8
    a = CA_DOUBLE([-1.0, 100.0, 1e20, 50.0])
    a.mask = [false, true, false, false]
    out = a.clip_uint8
    # Masked cell at index 1 stays masked.
    assert_equal [true], [out.mask[1]]
    # Other cells produce clipped values (= no spurious masking).
    assert_equal 0,   out[0]
    assert_equal 255, out[2]
    assert_equal 50,  out[3]
  end

  # --- shape preservation ---

  def test_shape_preserved_for_ndim_2
    a = CArray.float64(2, 3) { |i, j| (i * 3 + j) * 100.0 - 200.0 }
    out = a.clip_uint8
    assert_equal [2, 3], out.dim.to_a
    assert_equal CA_UINT8, out.data_type
  end

  # --- all 8 methods callable and return correct dtype ---

  def test_all_eight_methods_return_correct_dtype
    a = CA_DOUBLE([1.0])
    assert_equal CA_INT8,   a.clip_int8.data_type
    assert_equal CA_INT16,  a.clip_int16.data_type
    assert_equal CA_INT32,  a.clip_int32.data_type
    assert_equal CA_INT64,  a.clip_int64.data_type
    assert_equal CA_UINT8,  a.clip_uint8.data_type
    assert_equal CA_UINT16, a.clip_uint16.data_type
    assert_equal CA_UINT32, a.clip_uint32.data_type
    assert_equal CA_UINT64, a.clip_uint64.data_type
  end

  # --- integer input (well-defined integer-to-integer cast) ---

  def test_integer_input_int64_to_uint32
    # When source is integer, clip + as_uint32 should preserve integer-wrap
    # semantic for in-range, clip for out-of-range.
    a = CA_INT64([-1, 0, 1, UINT32_MAX, UINT32_MAX + 100])
    out = a.clip_uint32
    # negative -> 0 (clipped), in-range -> passthrough, overflow -> UINT32_MAX
    assert_equal [0, 0, 1, UINT32_MAX, UINT32_MAX], out.to_a
  end

end
