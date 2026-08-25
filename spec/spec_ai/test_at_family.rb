# PROPOSAL_AT_FAMILY G.1: scatter_add! tests.
# Covers PROPOSAL §3 axes 1-9 + §4 acceptance criteria.
#
# G.2 will extend this file to cover scatter_sub! / scatter_min! / scatter_max!.

require 'test/unit'
require 'carray'

class TestAtFamily < Test::Unit::TestCase

  NUMERIC_DTYPES = [
    CA_INT8,   CA_INT16,  CA_INT32,  CA_INT64,
    CA_UINT8,  CA_UINT16, CA_UINT32, CA_UINT64,
    CA_FLOAT32, CA_FLOAT64,
  ]

  # ---- G.1 scatter_add!: basic behavior across all numeric dtypes ----

  def test_scatter_add_basic_each_numeric_dtype
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [5]).fill(0)
      a.scatter_add!(CA_SIZE([0, 2, 4]), 3)
      assert_equal([3, 0, 3, 0, 3], a.to_a, "dtype #{dt} (basic)")
    end
  end

  # ---- §3.3 (axis 3): duplicate addrs are unbuffered (sequential) ----

  def test_scatter_add_duplicates_unbuffered
    # PROPOSAL §3.3 example: addrs=[1,1,1], vals=[10,20,30] → [0,60,0]
    a = CA_DOUBLE([0, 0, 0])
    a.scatter_add!(CA_SIZE([1, 1, 1]), CA_DOUBLE([10, 20, 30]))
    assert_equal([0.0, 60.0, 0.0], a.to_a)

    # Mixed: addrs=[0,1,1,2,1], vals=[10,1,2,3,4]  →  [10, 1+2+4, 3] = [10, 7, 3]
    b = CA_DOUBLE([0, 0, 0])
    b.scatter_add!(CA_SIZE([0, 1, 1, 2, 1]), CA_DOUBLE([10, 1, 2, 3, 4]))
    assert_equal([10.0, 7.0, 3.0], b.to_a)
  end

  # ---- §3.2 (axis 2): vals = scalar broadcast ----

  def test_scatter_add_scalar_broadcast_float
    a = CA_DOUBLE([0, 0, 0, 0])
    a.scatter_add!(CA_SIZE([0, 2, 0]), 1.5)
    assert_equal([3.0, 0.0, 1.5, 0.0], a.to_a)
  end

  def test_scatter_add_scalar_broadcast_fixnum
    a = CA_INT64([0, 0, 0, 0])
    a.scatter_add!(CA_SIZE([0, 2, 0]), 5)
    assert_equal([10, 0, 5, 0], a.to_a)
  end

  # ---- §3.6 (axis 6): addrs polymorphism (CArray or Ruby Array) ----

  def test_scatter_add_addrs_ruby_array
    a = CA_FLOAT64([0, 0, 0])
    a.scatter_add!([0, 1, 2], 1.5)
    assert_equal([1.5, 1.5, 1.5], a.to_a)
  end

  def test_scatter_add_addrs_carray
    a = CA_INT32([0, 0, 0])
    a.scatter_add!(CA_SIZE([0, 1, 2]), 1)
    assert_equal([1, 1, 1], a.to_a)
  end

  # ---- §3.7 (axis 7): mask handling — pair skip semantics ----

  def test_scatter_add_self_masked_skips_update
    a = CA_DOUBLE([0, 0, 0])
    a[1] = UNDEF
    a.scatter_add!(CA_SIZE([0, 1, 2]), 10.0)
    assert_equal(10.0, a[0])
    assert_equal(true, a.mask[1])
    assert_equal(10.0, a[2])
  end

  def test_scatter_add_addrs_masked_skips_pair
    a = CA_DOUBLE([0, 0, 0])
    addrs = CA_SIZE([0, 1, 2])
    addrs[1] = UNDEF
    a.scatter_add!(addrs, 10.0)
    assert_equal([10.0, 0.0, 10.0], a.to_a)
  end

  def test_scatter_add_vals_masked_skips_pair
    a = CA_DOUBLE([0, 0, 0])
    vals = CA_DOUBLE([1, 2, 3])
    vals[1] = UNDEF
    a.scatter_add!(CA_SIZE([0, 1, 2]), vals)
    assert_equal([1.0, 0.0, 3.0], a.to_a)
  end

  # ---- §3.9 (axis 9): bounds check raises IndexError ----

  def test_scatter_add_out_of_bounds_raises
    a = CA_DOUBLE([0, 0, 0])
    assert_raise(IndexError) {
      a.scatter_add!(CA_SIZE([0, 5]), 1.0)
    }
  end

  def test_scatter_add_negative_addr_normalizes_python_style
    # CArray convention (CA_CHECK_INDEX): negative addr normalizes from end.
    # -1 maps to elements-1, like ca[-1] / a.fetch_addr(-1).
    a = CA_DOUBLE([0, 0, 0])
    a.scatter_add!(CA_SIZE([-1, 0]), 1.0)
    assert_equal([1.0, 0.0, 1.0], a.to_a)
  end

  def test_scatter_add_truly_out_of_bounds_negative_raises
    # -5 for elements=3 normalizes to -2 → still out of range, raises.
    a = CA_DOUBLE([0, 0, 0])
    assert_raise(IndexError) {
      a.scatter_add!(CA_SIZE([-5, 0]), 1.0)
    }
  end

  # ---- §3.8 (axis 8): silent data_type cast ----

  def test_scatter_add_silent_truncate_float_to_int
    a = CA_INT32([0, 0, 0])
    a.scatter_add!(CA_SIZE([0, 1, 2]), CA_DOUBLE([1.5, 2.7, 3.9]))
    assert_equal([1, 2, 3], a.to_a)
  end

  def test_scatter_add_int8_overflow_silent_truncate
    a = CA_INT8([0, 0, 0])
    a.scatter_add!(CA_SIZE([0]), 300)  # 300 mod 256 = 44
    assert_equal(44, a[0])
  end

  # ---- §2.1: empty addrs is a no-op ----

  def test_scatter_add_empty_addrs_noop
    a = CA_INT32([1, 2, 3])
    a.scatter_add!(CA_SIZE([]), 99)
    assert_equal([1, 2, 3], a.to_a)
  end

  # ---- frozen self ----

  def test_scatter_add_frozen_raises
    a = CA_DOUBLE([0, 0, 0]).freeze
    assert_raise(FrozenError) {
      a.scatter_add!(CA_SIZE([0]), 1.0)
    }
  end

  # ---- non-numeric reject ----

  def test_scatter_add_object_dtype_raises
    a = CArray.object(3) { 0 }
    assert_raise(CArray::DataTypeError) {
      a.scatter_add!(CA_SIZE([0]), 1)
    }
  end

  def test_scatter_add_boolean_dtype_raises
    a = CArray.boolean(3) { 0 }
    assert_raise(CArray::DataTypeError) {
      a.scatter_add!(CA_SIZE([0]), 1)
    }
  end

  # ---- length mismatch ----

  def test_scatter_add_length_mismatch_raises
    a = CA_DOUBLE([0, 0, 0])
    assert_raise(ArgumentError) {
      a.scatter_add!(CA_SIZE([0, 1, 2]), CA_DOUBLE([1, 2]))
    }
  end

  # ---- virtual self (CABlock, CARefer) — attach lifecycle path ----

  def test_scatter_add_virtual_self_cablock
    a = CA_INT32([[0, 0, 0], [0, 0, 0]])
    sub = a[0, nil]   # CABlock view of row 0
    sub.scatter_add!(CA_SIZE([0, 2]), 7)
    assert_equal([[7, 0, 7], [0, 0, 0]], a.to_a)
  end

  def test_scatter_add_virtual_self_carefer
    a = CA_FLOAT64([1, 2, 3, 4, 5, 6])
    v = a.refer(CA_FLOAT64, [2, 3])  # CARefer reshape
    v.scatter_add!(CA_SIZE([0, 3]), 10.0)
    assert_equal([11.0, 2.0, 3.0, 14.0, 5.0, 6.0], a.to_a)
  end

  # ---- mixed dtype dispatch sanity ----

  def test_scatter_add_float32_carray_vals
    a = CArray.float32(5).fill(0)
    a.scatter_add!(CA_SIZE([0, 1, 4]), CArray.float32(3).seq!(1.0, 1.0))  # [1,2,3]
    assert_in_delta(1.0, a[0], 1e-6)
    assert_in_delta(2.0, a[1], 1e-6)
    assert_in_delta(3.0, a[4], 1e-6)
  end

  def test_scatter_add_uint8_carray_vals
    a = CArray.uint8(4).fill(0)
    a.scatter_add!(CA_SIZE([0, 1, 2, 3]), CArray.uint8(4).seq!(10, 1))
    assert_equal([10, 11, 12, 13], a.to_a)
  end

  # ---------------------------------------------------------------
  # G.2: scatter_sub! / scatter_min! / scatter_max!
  # ---------------------------------------------------------------

  # ---- scatter_sub! basic + symmetry with scatter_add! ----

  def test_scatter_sub_basic_each_numeric_dtype
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [5]).fill(10)
      a.scatter_sub!(CA_SIZE([0, 2, 4]), 3)
      assert_equal([7, 10, 7, 10, 7], a.to_a, "scatter_sub! dtype #{dt}")
    end
  end

  def test_scatter_sub_duplicates_unbuffered
    a = CA_DOUBLE([100, 100, 100])
    a.scatter_sub!(CA_SIZE([1, 1, 1]), CA_DOUBLE([10, 20, 30]))
    assert_equal([100.0, 40.0, 100.0], a.to_a)
  end

  def test_scatter_sub_scalar_broadcast
    a = CA_INT32([10, 20, 30, 40])
    a.scatter_sub!(CA_SIZE([0, 2]), 5)
    assert_equal([5, 20, 25, 40], a.to_a)
  end

  def test_scatter_sub_mask_pair_skip
    a = CA_DOUBLE([10, 10, 10])
    a[1] = UNDEF
    a.scatter_sub!(CA_SIZE([0, 1, 2]), 3.0)
    assert_equal(7.0, a[0])
    assert_equal(true, a.mask[1])
    assert_equal(7.0, a[2])
  end

  # ---- scatter_min! basic ----

  def test_scatter_min_basic_each_numeric_dtype
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [5]).fill(50)
      a.scatter_min!(CA_SIZE([0, 2, 4]), 30)
      assert_equal([30, 50, 30, 50, 30], a.to_a, "scatter_min! dtype #{dt}")
    end
  end

  def test_scatter_min_duplicates_take_minimum
    a = CA_INT32([100, 100, 100])
    a.scatter_min!(CA_SIZE([0, 0, 0]), CA_INT32([50, 30, 40]))
    # successive min: 100→50→30→ (30 vs 40 keeps 30)
    assert_equal([30, 100, 100], a.to_a)
  end

  def test_scatter_min_nan_in_vals_treated_as_missing
    # fmin policy: NaN at vals side is treated as missing → keep self.
    a = CA_DOUBLE([5.0, 5.0])
    a.scatter_min!(CA_SIZE([0, 1]), CA_DOUBLE([Float::NAN, 3.0]))
    assert_equal([5.0, 3.0], a.to_a)
  end

  def test_scatter_min_nan_in_self_treated_as_missing
    # fmin policy: NaN at self side is treated as missing → take vals.
    a = CA_DOUBLE([Float::NAN, 5.0])
    a.scatter_min!(CA_SIZE([0, 1]), CA_DOUBLE([3.0, Float::NAN]))
    assert_equal([3.0, 5.0], a.to_a)
  end

  def test_scatter_min_scalar_clip_from_above
    # scattered clip: positions 0,2 clamped to ≤ 10
    a = CA_INT32([20, 5, 30, 8])
    a.scatter_min!(CA_SIZE([0, 2]), 10)
    assert_equal([10, 5, 10, 8], a.to_a)
  end

  # ---- scatter_max! basic ----

  def test_scatter_max_basic_each_numeric_dtype
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [5]).fill(10)
      a.scatter_max!(CA_SIZE([0, 2, 4]), 30)
      assert_equal([30, 10, 30, 10, 30], a.to_a, "scatter_max! dtype #{dt}")
    end
  end

  def test_scatter_max_duplicates_take_maximum
    a = CA_INT32([0, 0, 0])
    a.scatter_max!(CA_SIZE([0, 0, 0]), CA_INT32([5, 9, 3]))
    # successive max: 0→5→9→ (9 vs 3 keeps 9)
    assert_equal([9, 0, 0], a.to_a)
  end

  def test_scatter_max_nan_in_vals_treated_as_missing
    a = CA_DOUBLE([5.0, 5.0])
    a.scatter_max!(CA_SIZE([0, 1]), CA_DOUBLE([Float::NAN, 7.0]))
    assert_equal([5.0, 7.0], a.to_a)
  end

  def test_scatter_max_scalar_relu_pattern
    # ReLU at positions: clamp negative cells to ≥ 0
    a = CA_INT32([-1, 5, -3, 2])
    a.scatter_max!(CA_SIZE([0, 2]), 0)
    assert_equal([0, 5, 0, 2], a.to_a)
  end

  def test_scatter_max_mask_pair_skip
    a = CA_DOUBLE([5, 5, 5])
    vals = CA_DOUBLE([10, 20, 30])
    vals[1] = UNDEF
    a.scatter_max!(CA_SIZE([0, 1, 2]), vals)
    assert_equal([10.0, 5.0, 30.0], a.to_a)
  end

  # ---- virtual self path symmetry ----

  def test_scatter_min_virtual_self_cablock
    a = CA_INT32([[50, 50, 50], [50, 50, 50]])
    sub = a[0, nil]
    sub.scatter_min!(CA_SIZE([0, 2]), 10)
    assert_equal([[10, 50, 10], [50, 50, 50]], a.to_a)
  end

  # ---- non-numeric reject ----

  def test_scatter_sub_boolean_dtype_raises
    a = CArray.boolean(3) { 0 }
    assert_raise(CArray::DataTypeError) {
      a.scatter_sub!(CA_SIZE([0]), 1)
    }
  end

  def test_scatter_min_object_dtype_raises
    a = CArray.object(3) { 0 }
    assert_raise(CArray::DataTypeError) {
      a.scatter_min!(CA_SIZE([0]), 1)
    }
  end

  # ---- empty addrs no-op ----

  def test_scatter_sub_empty_addrs_noop
    a = CA_INT32([1, 2, 3])
    a.scatter_sub!(CA_SIZE([]), 99)
    assert_equal([1, 2, 3], a.to_a)
  end

  def test_scatter_min_empty_addrs_noop
    a = CA_INT32([1, 2, 3])
    a.scatter_min!(CA_SIZE([]), 99)
    assert_equal([1, 2, 3], a.to_a)
  end

  # ---------------------------------------------------------------
  # G.6: scatter_mul! — scatter-multiply (Bayesian patch / weight composition)
  # ---------------------------------------------------------------

  def test_scatter_mul_basic_each_numeric_dtype
    NUMERIC_DTYPES.each do |dt|
      a = CArray.new(dt, [5]).fill(2)
      a.scatter_mul!(CA_SIZE([0, 2, 4]), 3)
      assert_equal([6, 2, 6, 2, 6], a.to_a, "scatter_mul! dtype #{dt}")
    end
  end

  def test_scatter_mul_duplicates_accumulate_multiplicatively
    # Bayesian likelihood pattern: 1 * 2 * 3 * 4 = 24 at position 1
    a = CA_DOUBLE([1, 1, 1])
    a.scatter_mul!(CA_SIZE([1, 1, 1]), CA_DOUBLE([2, 3, 4]))
    assert_equal([1.0, 24.0, 1.0], a.to_a)
  end

  def test_scatter_mul_scalar_broadcast
    a = CA_INT32([2, 3, 4, 5])
    a.scatter_mul!(CA_SIZE([0, 2]), 10)
    assert_equal([20, 3, 40, 5], a.to_a)
  end

  def test_scatter_mul_nan_propagates_unlike_min_max
    # scatter_mul! uses standard C arithmetic (NOT fmin-style missing rule).
    # scatter_min!/scatter_max! treat NaN as missing; scatter_mul! lets NaN propagate.
    a = CA_DOUBLE([2.0, 2.0])
    a.scatter_mul!(CA_SIZE([0]), Float::NAN)
    assert(a[0].nan?)
    assert_equal(2.0, a[1])
  end

  def test_scatter_mul_int_overflow_silent_wrap
    # int8: 100 * 3 = 300 → 300 mod 256 = 44 (C wrap-around semantic)
    a = CA_INT8([100])
    a.scatter_mul!(CA_SIZE([0]), 3)
    assert_equal(44, a[0])
  end

  def test_scatter_mul_mask_pair_skip
    a = CA_DOUBLE([2, 2, 2])
    vals = CA_DOUBLE([10, 20, 30])
    vals[1] = UNDEF
    a.scatter_mul!(CA_SIZE([0, 1, 2]), vals)
    assert_equal([20.0, 2.0, 60.0], a.to_a)
  end

  def test_scatter_mul_virtual_self_cablock
    a = CA_INT32([[2, 2, 2], [2, 2, 2]])
    sub = a[0, nil]
    sub.scatter_mul!(CA_SIZE([0, 2]), 10)
    assert_equal([[20, 2, 20], [2, 2, 2]], a.to_a)
  end

  def test_scatter_mul_empty_addrs_noop
    a = CA_DOUBLE([5, 5, 5])
    a.scatter_mul!(CA_SIZE([]), 99.0)
    assert_equal([5.0, 5.0, 5.0], a.to_a)
  end

  def test_scatter_mul_boolean_dtype_raises
    a = CArray.boolean(3) { 0 }
    assert_raise(CArray::DataTypeError) {
      a.scatter_mul!(CA_SIZE([0]), 1)
    }
  end

  def test_scatter_mul_silent_truncate_float_to_int
    a = CA_INT32([10, 10, 10])
    a.scatter_mul!(CA_SIZE([0, 1, 2]), CA_DOUBLE([1.7, 2.3, 3.9]))
    # vals cast to int32: 1, 2, 3
    assert_equal([10, 20, 30], a.to_a)
  end

end
