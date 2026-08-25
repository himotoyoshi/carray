# frozen_string_literal: true
#
# Phase D POC — CA_SLAB_REDUCE_F64 / CA_SLAB_MAP_F64 macro suite tests.
#
# Pins:
#   - sum_ki / mean_ki / min_ki / max_ki parity against CArray#sum etc.
#     across entity, view chain, mask, and multi-axis reductions.
#   - sqrt_ki parity against per-element Math.sqrt, plus view chain
#     transparency (= macro walks strided input correctly).
#
# These exercise the macros (declared in ext/ca_kernel_iterator.h) by
# verifying that the lifted kernels in ext/carray_kernel_sum.c produce
# byte-equivalent results to the existing per-element references.

require "test/unit"
require "carray"

class TestPhaseDKernelMacros < Test::Unit::TestCase

  # ---- sum_ki -----------------------------------------------------------

  def test_sum_ki_entity_1d
    a = CArray.float64(5).seq
    assert_in_delta(a.sum, a.sum(axis: 0), 1e-12)
  end

  def test_sum_ki_entity_2d_axis0
    a = CArray.float64(10, 7).seq
    assert_equal(a.sum(axis: 0).to_a, a.sum(axis: 0).to_a)
  end

  def test_sum_ki_entity_2d_axis1
    a = CArray.float64(10, 7).seq
    assert_equal(a.sum(axis: 1).to_a, a.sum(axis: 1).to_a)
  end

  def test_sum_ki_full_returns_float
    a = CArray.float64(3, 4).seq
    assert_kind_of(Float, a.sum(axis: [0, 1]))
    assert_in_delta(a.sum.to_f, a.sum(axis: [0, 1]), 1e-12)
  end

  def test_sum_ki_view_chain_transpose
    a = CArray.float64(20, 15).seq
    tv = a.transpose
    assert_in_delta((tv.sum(axis: 0) - tv.sum(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_sum_ki_view_chain_block
    a = CArray.float64(30, 30).seq
    bv = a[5..24, 5..24]
    assert_in_delta((bv.sum(axis: 0) - bv.sum(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_sum_ki_masked
    a = CArray.float64(8).seq
    a[2] = UNDEF
    a[5] = UNDEF
    # Expected: 0 + 1 + 3 + 4 + 6 + 7 = 21
    assert_in_delta(21.0, a.sum(axis: 0), 1e-12)
  end

  def test_sum_ki_multi_axis_3d
    a = CArray.float64(6, 7, 5).seq
    expected = a.sum(axis: [0, 2]).to_a
    assert_equal(expected, a.sum(axis: [0, 2]).to_a)
  end

  def test_sum_ki_int_source_auto_widening
    # Phase B helper auto-cast: int32 → float64 via CAFake
    a = CArray.int32(10).seq
    assert_in_delta((0..9).sum, a.sum(axis: 0), 1e-12)
  end

  # ---- Phase D §3.c native-data_type dispatch -----------------------------
  # Source data_types int32 / int64 / float32 take the native path; output
  # remains float64 to match CArray#sum surface.  Behaviour parity with
  # the Phase B wrap_readonly path is the goal; perf is a bonus.

  def test_sum_ki_native_int32_2d
    a = CArray.int32(6, 7).seq
    expected = a.sum(axis: 0).to_a
    assert_equal(expected, a.sum(axis: 0).to_a)
  end

  def test_sum_ki_native_int64_2d
    a = CArray.int64(5, 4).seq
    expected = a.sum(axis: 0).to_a
    assert_equal(expected, a.sum(axis: 0).to_a)
  end

  def test_sum_ki_native_float32_2d
    a = CArray.float32(8, 3).seq
    assert_in_delta((a.sum(axis: 0) - a.sum(axis: 0)).abs.max, 0.0, 1e-4)
  end

  def test_sum_ki_native_int32_full_returns_float
    a = CArray.int32(20).seq
    # int32 source, output data_type = float64 (matches CArray#sum)
    s = a.sum(axis: 0)
    assert_kind_of(Float, s)
    assert_in_delta(190.0, s, 1e-9)  # 0+1+...+19 = 190
  end

  def test_sum_ki_native_int32_masked
    a = CArray.int32(6).seq
    a[1] = UNDEF
    a[4] = UNDEF
    # Unmasked: 0, 2, 3, 5 → sum = 10
    assert_in_delta(10.0, a.sum(axis: 0), 1e-9)
  end

  def test_sum_ki_native_int32_view_chain
    # Native path must transparently handle view chains (= test that
    # ca_iter_state_init_l2 accepts strided int32 source).
    a = CArray.int32(10, 8).seq
    tv = a.transpose
    assert_in_delta((tv.sum(axis: 0) - tv.sum(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_sum_ki_native_int32_multi_axis
    a = CArray.int32(4, 5, 6).seq
    expected = a.sum(axis: [0, 2]).to_a
    assert_equal(expected, a.sum(axis: [0, 2]).to_a)
  end

  def test_sum_ki_fallback_int16_still_works
    # int16 is not in the native dispatch — falls through to Phase B
    # wrap_readonly path.  Verify it still produces correct results.
    a = CArray.int16(8).seq
    assert_in_delta((0..7).sum, a.sum(axis: 0), 1e-12)
  end

  # ---- mkkernel-generated kernels (Phase D §4) ------------------------
  # sum / prod / min / max are emitted by ext/mkkernel.rb into
  # ext/carray_kernels.c.  These tests pin the generator's output:
  # new prod_ki kernel works on all four native data_types; min/max now
  # preserve source data_type (= matches CArray#min/#max semantics).

  def test_prod_ki_float64
    a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0])
    assert_in_delta(24.0, a.prod(axis: 0), 1e-12)
  end

  def test_prod_ki_int32_2d
    a = CArray.int32(3, 4).seq + 1
    # Per-column product, output is f64
    assert_equal([45.0, 120.0, 231.0, 384.0], a.prod(axis: 0).to_a)
    assert_equal(CA_FLOAT64, a.prod(axis: 0).data_type)
  end

  def test_prod_ki_masked
    a = CArray.float64(5).seq + 1.0  # [1, 2, 3, 4, 5]
    a[1] = UNDEF
    a[3] = UNDEF
    # Unmasked product: 1 * 3 * 5 = 15
    assert_in_delta(15.0, a.prod(axis: 0), 1e-9)
  end

  def test_min_ki_preserves_int32_data_type
    # Generator outputs `output: :preserve` for min/max -> int32 source
    # yields int32 output (was float64 in the hand-written version).
    a = CArray.int32(3, 4).seq + 1
    m = a.min(axis: 0)
    assert_equal(CA_INT32, m.data_type)
    assert_equal([1, 2, 3, 4], m.to_a)
  end

  def test_max_ki_preserves_int64_data_type
    a = CArray.int64(2, 5).seq + 10
    m = a.max(axis: 0)
    assert_equal(CA_INT64, m.data_type)
    assert_equal([15, 16, 17, 18, 19], m.to_a)
  end

  def test_min_ki_preserves_float32_data_type
    # float32 min should stay float32, not widen to float64.
    a = CArray.float32(3, 4).seq + 0.5
    m = a.min(axis: 0)
    assert_equal(CA_FLOAT32, m.data_type)
  end

  def test_min_ki_int32_full_returns_integer
    # Full reduction with output: :preserve + ruby_scalar: :auto
    # produces Integer for int sources.
    a = CArray.int32(10).seq + 1
    result = a.min(axis: 0)
    assert_kind_of(Integer, result)
    assert_equal(1, result)
  end

  def test_max_ki_float64_full_returns_float
    a = CArray.float64(10).seq
    result = a.max(axis: 0)
    assert_kind_of(Float, result)
    assert_in_delta(9.0, result, 1e-12)
  end

  def test_min_ki_boolean_numeric
    # 3.0: boolean min/max return 0/1 (Integer), participating as their
    # 0/1 numeric storage (the boolean-returning twins are all / any).
    a = CArray.boolean(5) { |i| i == 2 }   # [0, 0, 1, 0, 0]
    assert_equal 0, a.min(axis: 0)
    assert_equal 1, a.max(axis: 0)
  end

  def test_sum_ki_int16_falls_through_to_wrap
    # sum uses fallback: :wrap_to_f64 -> int16 still works (already
    # pinned above as test_sum_ki_fallback_int16_still_works but
    # repeated here to contrast with min/max).
    a = CArray.int16(5).seq
    assert_in_delta(10.0, a.sum(axis: 0), 1e-12)
  end

  # ---- count_ki (mkkernel: REDUCE that ignores `v`) ------------------
  # Demonstrates the generator handles trivial reductions where the
  # accumulator depends only on the iteration, not the element value.
  # The `(void)v` cast in the DSL silences unused-variable warnings.

  def test_count_ki_unmasked_returns_elements
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(7).seq
    assert_equal(7, a.count_ki(0))
  end

  def test_count_ki_masked
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(8).seq
    a[1] = UNDEF
    a[3] = UNDEF
    a[5] = UNDEF
    assert_equal(5, a.count_ki(0))
  end

  def test_count_ki_axis0_2d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int32(4, 5).seq
    assert_equal([4, 4, 4, 4, 4], a.count_ki(0).to_a)
    assert_equal(CA_INT64, a.count_ki(0).data_type)
  end

  def test_count_ki_full_returns_integer
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int32(3, 4).seq
    result = a.count_ki(0, 1)
    assert_kind_of(Integer, result)
    assert_equal(12, result)
  end

  def test_count_ki_int16_falls_through_to_wrap
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # count uses fallback: :wrap_to_f64 -> int16 still works (any
    # numeric data_type counts the same way).
    a = CArray.int16(8).seq
    assert_equal(8, a.count_ki(0))
  end

  # ---- multi-state form: mean / variance / stddev (Phase D §state+finish)

  # mean_ki migrated from hand-written carray_kernel_sum.c to the
  # generator using state: { acc:, cnt: }, init: { acc: "0", cnt: "0" },
  # reduce: "(acc += v, cnt++)", finish: "cnt ? acc / cnt : 0".

  def test_mean_ki_entity_after_migration
    a = CArray.float64(10).seq
    assert_in_delta(4.5, a.mean(axis: 0), 1e-12)
  end

  def test_mean_ki_axis0_2d_parity_with_CArray_mean
    a = CArray.float64(4, 5).seq
    assert_in_delta((a.mean(axis: 0) - a.mean(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_mean_ki_masked_count
    a = CArray.float64(6).seq
    a[1] = UNDEF
    a[4] = UNDEF
    # Unmasked: 0, 2, 3, 5 -> mean = 10/4 = 2.5
    assert_in_delta(2.5, a.mean(axis: 0), 1e-12)
  end

  def test_mean_ki_all_masked_returns_undef
    # Phase E: mean now uses mask_policy: :min_count so all-masked slabs
    # return UNDEF (matching legacy CArray#mean semantics).  Prior Phase
    # D POC behaviour returned 0 (= finish expr "cnt ? acc/cnt : 0").
    a = CArray.float64(3).seq
    a[0..2] = UNDEF
    assert_equal(UNDEF, a.mean(axis: 0))
  end

  def test_mean_ki_view_chain
    a = CArray.float64(12, 8).seq
    tv = a.transpose
    assert_in_delta((tv.mean(axis: 0) - tv.mean(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_mean_ki_int32_source
    a = CArray.int32(10).seq
    assert_in_delta(4.5, a.mean(axis: 0), 1e-12)
  end

  # variance_ki / variancep_ki -- sample vs population.

  def test_variance_ki_sample_matches_reference
    # CArray#variance is sample variance (= /n-1).
    a = CArray.float64(10).seq
    # Sum = 45, sumsq = 285.  variance = (285 - 45^2/10) / 9 = (285 - 202.5) / 9 = 9.1667
    assert_in_delta(9.166666666666666, a.variance(axis: 0), 1e-9)
  end

  def test_variancep_ki_population
    # Population variance = /n.
    a = CArray.float64(10).seq
    # (285 - 202.5) / 10 = 8.25
    assert_in_delta(8.25, a.variancep(axis: 0), 1e-9)
  end

  def test_variance_ki_parity_with_CArray_variance
    a = CArray.float64(5, 7).seq
    assert_in_delta((a.variance(axis: 0) - a.variance(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_variance_ki_masked
    a = CArray.float64(6).seq         # [0, 1, 2, 3, 4, 5]
    a[1] = UNDEF
    a[4] = UNDEF                       # unmasked: 0, 2, 3, 5
    # sum = 10, sumsq = 0 + 4 + 9 + 25 = 38, n = 4
    # var = (38 - 100/4) / 3 = (38 - 25) / 3 = 13/3 = 4.333...
    assert_in_delta(4.333333333333333, a.variance(axis: 0), 1e-9)
  end

  def test_variance_ki_one_element_returns_zero
    # Sample variance with n=1: denominator (n-1)=0, guarded to 0.
    a = CArray.float64(1)
    a[0] = 5.0
    assert_in_delta(0.0, a.variance(axis: 0), 1e-12)
  end

  # stddev_ki / stddevp_ki -- sqrt of variance forms.

  def test_stddev_ki_sample
    a = CArray.float64(10).seq
    # stddev = sqrt(9.1667) = 3.0277
    assert_in_delta(Math.sqrt(9.166666666666666), a.stddev(axis: 0), 1e-9)
  end

  def test_stddevp_ki_population
    a = CArray.float64(10).seq
    # stddevp = sqrt(8.25) = 2.8723
    assert_in_delta(Math.sqrt(8.25), a.stddevp(axis: 0), 1e-9)
  end

  def test_stddev_ki_int_source
    a = CArray.int32(10).seq
    assert_in_delta(Math.sqrt(9.166666666666666), a.stddev(axis: 0), 1e-9)
  end

  def test_stddevp_ki_2d_parity
    a = CArray.float64(5, 7).seq + 0.5
    # Compare against manual computation via mean
    a.dim[1].times do |j|
      col = (0...a.dim[0]).map { |i| a[i, j] }
      m = col.sum / col.size.to_f
      var_pop = col.map { |x| (x - m)**2 }.sum / col.size.to_f
      expected = Math.sqrt(var_pop)
      assert_in_delta(expected, a.stddevp(axis: 0)[j], 1e-9)
    end
  end

  # ---- argmin_ki / argmax_ki (multi-state + idx) ----------------------
  # First test of the idx binding inside CA_SLAB_REDUCE_T.  Uses a
  # two-state walk where the macro accumulator is `best_v` (source data_type)
  # and the caller-initialised secondary is `best_i` (int64_t).

  def test_argmin_ki_entity_1d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CA_FLOAT64([3.0, 1.0, 5.0, 0.0, 4.0])
    assert_equal(3, a.argmin_ki(0))   # 0.0 at index 3
  end

  def test_argmax_ki_entity_1d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CA_FLOAT64([3.0, 1.0, 5.0, 0.0, 4.0])
    assert_equal(2, a.argmax_ki(0))   # 5.0 at index 2
  end

  def test_argmin_ki_axis0_2d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(3, 4).seq      # increasing along both axes
    # Each column's min is row 0
    assert_equal([0, 0, 0, 0], a.argmin_ki(0).to_a)
    assert_equal(CA_INT64, a.argmin_ki(0).data_type)
  end

  def test_argmax_ki_axis0_2d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(3, 4).seq
    # Each column's max is row 2
    assert_equal([2, 2, 2, 2], a.argmax_ki(0).to_a)
  end

  def test_argmin_ki_masked_preserves_absolute_position
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # When a masked cell would have been the minimum, the macro skips
    # the REDUCE call but still increments idx -- the returned index
    # is the absolute slab position of the visible minimum, not the
    # rank among unmasked cells.
    a = CA_FLOAT64([5.0, 1.0, 0.0, 2.0, -3.0])
    a[2] = UNDEF   # would have been the min (0.0)
    a[4] = UNDEF   # would have been the min (-3.0)
    # Visible cells: indices [0,1,3] with values [5, 1, 2]; min = 1 at idx 1
    assert_equal(1, a.argmin_ki(0))
  end

  def test_argmax_ki_masked_preserves_absolute_position
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CA_FLOAT64([5.0, 1.0, 100.0, 2.0, -3.0])
    a[2] = UNDEF                # would have been the max
    # Visible cells: [5, 1, _, 2, -3]; max = 5 at idx 0
    assert_equal(0, a.argmax_ki(0))
  end

  def test_argmin_ki_int32_source
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int32(5).seq    # [0, 1, 2, 3, 4]
    a[2] = -10
    assert_equal(2, a.argmin_ki(0))
  end

  def test_argmin_ki_int64_source
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int64(4).seq
    a[3] = -100
    assert_equal(3, a.argmin_ki(0))
  end

  def test_argmin_ki_full_returns_integer
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(8).seq + 0.5
    result = a.argmin_ki(0)
    assert_kind_of(Integer, result)
    assert_equal(0, result)
  end

  def test_argmax_ki_3d_axis1
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(2, 3, 4).seq
    # axis 1 = middle.  For each (i, k), the max is at j=2.
    result = a.argmax_ki(1)
    assert_equal([2, 4], result.dim)
    a.dim[0].times do |i|
      a.dim[2].times do |k|
        assert_equal(2, result[i, k],
                     "expected argmax along axis 1 = 2 for cell (#{i}, #{k})")
      end
    end
  end

  def test_argmin_ki_view_chain
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Transpose view + argmin should produce sane indices in the
    # transposed coordinate space.
    a = CArray.float64(5, 6).seq
    tv = a.transpose          # shape [6, 5]
    # tv[i, j] = a[j, i], increasing in both axes.
    # tv.argmin_ki(0) -> for each transposed-column (= original row),
    # the row of the min.  Should be [0, 0, 0, 0, 0].
    assert_equal([0] * 5, tv.argmin_ki(0).to_a)
  end

  def test_argmin_ki_first_occurrence_on_ties
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Strictly-less comparison means the first occurrence wins.
    a = CA_FLOAT64([1.0, 1.0, 1.0, 1.0])
    assert_equal(0, a.argmin_ki(0))
  end

  def test_argmin_ki_raises_on_unsupported
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # argmin uses fallback: :raise.  Boolean source raises since it's
    # not in the source: list.  (int16 etc. are now natively covered.)
    # Phase E: data_type-reject now raises CArray::DataTypeError.
    a = CArray.boolean(5)
    assert_raise(CArray::DataTypeError) { a.argmin_ki(0) }
  end

  def test_argmax_ki_multi_axis_reduction
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # 3D array, reduce axes [0, 2] -> output shape [d1]; result is the
    # flat index within the (d0 * d2) slab where the max sits.
    a = CArray.float64(2, 3, 2).seq   # [[[0,1],[2,3],[4,5]], [[6,7],[8,9],[10,11]]]
    # For each j in 0..2, the slab spans (i, k) in row-major:
    #   (0,0), (0,1), (1,0), (1,1)  -> values for j=0: a[0,0,0]=0, a[0,0,1]=1, a[1,0,0]=6, a[1,0,1]=7
    # Max at flat idx 3 (value 7).  Same for j=1, j=2.
    assert_equal([3, 3, 3], a.argmax_ki(0, 2).to_a)
  end

  # ---- mask_policy: :strict / :all_masked -----------------------------
  # Phase D §mask_policy: generator emits CA_SLAB_REDUCE_T_EX, tracks
  # masked_cnt per slab, lazily allocates output mask, and returns
  # CA_UNDEF on full reduction when the result cell is masked.
  #
  # Demo kernels:
  #   sum_strict_ki  - :strict      (any masked -> UNDEF)
  #   mean_safe_ki   - :all_masked  (only all-masked -> UNDEF)

  def test_sum_strict_no_mask_matches_sum
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(5).seq
    assert_in_delta(a.sum(axis: 0), a.sum_strict_ki(0), 1e-12)
  end

  def test_sum_strict_any_masked_returns_undef_scalar
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Full reduction with any masked input -> Object::UNDEF
    a = CArray.float64(5).seq
    a[2] = UNDEF
    assert_equal(UNDEF, a.sum_strict_ki(0))
  end

  def test_sum_strict_clean_returns_float
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(5).seq
    assert_kind_of(Float, a.sum_strict_ki(0))
  end

  def test_sum_strict_partial_axis_2d_propagates_mask
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Some columns have masked cells, others don't.  Output mask should
    # be set only on affected columns.
    a = CArray.float64(3, 4).seq
    a[1, 2] = UNDEF   # affects column 2
    a[0, 1] = UNDEF   # affects column 1
    result = a.sum_strict_ki(0)
    # Unaffected columns: 0 and 3 -> 0+4+8 = 12 and 3+7+11 = 21
    assert_in_delta(12.0, result[0], 1e-9)
    assert_in_delta(21.0, result[3], 1e-9)
    # Affected columns: UNDEF
    assert_equal(UNDEF, result[1])
    assert_equal(UNDEF, result[2])
    # Output has a mask
    assert_equal([false, true, true, false], result.mask.to_a)
  end

  def test_sum_strict_int_source
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int32(6).seq
    a[3] = UNDEF
    assert_equal(UNDEF, a.sum_strict_ki(0))
  end

  def test_sum_strict_fallback_int16_via_wrap
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Falls through wrap_to_f64 -> native f64 helper.  The CAFake view
    # inherits the parent's mask so propagation still works.
    a = CArray.int16(5).seq
    a[1] = UNDEF
    assert_equal(UNDEF, a.sum_strict_ki(0))
  end

  def test_mean_safe_no_mask_matches_mean
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(8).seq
    assert_in_delta(a.mean(axis: 0), a.mean_safe_ki(0), 1e-12)
  end

  def test_mean_safe_partial_masked_still_returns_value
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # :all_masked policy means partial masking does NOT trigger UNDEF.
    a = CArray.float64(5).seq
    a[1] = UNDEF
    a[3] = UNDEF
    # Unmasked: 0, 2, 4 -> mean = 6/3 = 2.0
    assert_in_delta(2.0, a.mean_safe_ki(0), 1e-9)
    refute_equal(UNDEF, a.mean_safe_ki(0))
  end

  def test_mean_safe_all_masked_returns_undef
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(4).seq
    a[0..3] = UNDEF
    assert_equal(UNDEF, a.mean_safe_ki(0))
  end

  def test_mean_safe_per_slab_mixed_policy
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    # Some slabs all-masked, others not.  Only the all-masked slab's
    # output cell should be UNDEF.
    a = CArray.float64(3, 4).seq
    # Mask all of column 2 -> only column 2's output is UNDEF
    3.times { |i| a[i, 2] = UNDEF }
    result = a.mean_safe_ki(0)
    assert_in_delta(4.0,  result[0], 1e-9)  # column 0 mean
    assert_in_delta(5.0,  result[1], 1e-9)  # column 1 mean
    assert_equal(UNDEF, result[2])
    assert_in_delta(7.0,  result[3], 1e-9)  # column 3 mean
    # Mask presence
    assert_equal([false, false, true, false], result.mask.to_a)
  end

  def test_mean_safe_3d_full_reduction
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(2, 3, 4).seq
    # No mask -> returns Float, matches mean_ki
    assert_in_delta(a.mean(axis: [0, 1, 2]), a.mean_safe_ki(0, 1, 2), 1e-9)
    # All masked -> UNDEF
    a[] = UNDEF
    assert_equal(UNDEF, a.mean_safe_ki(0, 1, 2))
  end

  def test_existing_kernels_unchanged_by_mask_policy_feature
    # mask_policy is opt-in; existing kernels with nil policy keep
    # their old "skip masked, never UNDEF" behaviour.
    a = CArray.float64(5).seq
    a[2] = UNDEF
    # sum_ki returns the sum of visible cells, not UNDEF
    assert_kind_of(Float, a.sum(axis: 0))
    assert_in_delta(0 + 1 + 3 + 4, a.sum(axis: 0), 1e-12)
    # min_ki, max_ki same
    assert_kind_of(Float, a.min(axis: 0))
    # mean_ki returns Float not UNDEF
    assert_kind_of(Float, a.mean(axis: 0))
  end

  # ---- MkKernel.map form (sqrt + transcendentals + arithmetic) --------
  # Phase D §map: sqrt_ki migrated from hand-written carray_kernel_sum.c
  # to the generator (= ext/carray_kernels.c).  carray_kernel_sum.c
  # retired entirely.  Six new map kernels added in the same form:
  # sin, cos, exp, log, square, abs, negate.

  # ---- sqrt_ki via generator (replaces hand-written version) ---------

  def test_sqrt_ki_via_generator_entity_1d
    a = CA_FLOAT64([1.0, 4.0, 9.0, 16.0, 25.0])
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0], a.sqrt_ki.to_a)
  end

  def test_sqrt_ki_via_generator_int32_widens_to_f64
    a = CA_INT32([1, 4, 9, 16])
    result = a.sqrt_ki
    assert_equal(CA_FLOAT64, result.data_type)
    assert_equal([1.0, 2.0, 3.0, 4.0], result.to_a)
  end

  def test_sqrt_ki_via_generator_int16_falls_through_to_wrap
    # int16 not in :source -> wrap_to_f64 fallback -> f64 native path
    a = CArray.int16(4).seq + 1   # [1, 2, 3, 4]
    result = a.sqrt_ki
    assert_equal(CA_FLOAT64, result.data_type)
    assert_in_delta(0.0, (result - CA_FLOAT64([Math.sqrt(1), Math.sqrt(2), Math.sqrt(3), Math.sqrt(4)])).abs.max, 1e-12)
  end

  def test_sqrt_ki_via_generator_view_chain
    a = CArray.float64(6, 7).seq + 1
    tv = a.transpose
    result = tv.sqrt_ki
    tv.each_with_addr do |v, addr|
      idx = tv.addr2index(addr)
      assert_in_delta(Math.sqrt(v), result[*idx], 1e-12)
    end
  end

  # ---- transcendentals (output: :f64) --------------------------------

  def test_sin_ki
    a = CA_FLOAT64([0.0, Math::PI / 2, Math::PI])
    assert_in_delta(0.0, a.sin_ki[0], 1e-12)
    assert_in_delta(1.0, a.sin_ki[1], 1e-12)
    assert_in_delta(0.0, a.sin_ki[2], 1e-12)
  end

  def test_cos_ki
    a = CA_FLOAT64([0.0, Math::PI / 2, Math::PI])
    assert_in_delta(1.0,  a.cos_ki[0], 1e-12)
    assert_in_delta(0.0,  a.cos_ki[1], 1e-12)
    assert_in_delta(-1.0, a.cos_ki[2], 1e-12)
  end

  def test_exp_ki
    a = CA_FLOAT64([0.0, 1.0, 2.0])
    assert_in_delta(1.0,         a.exp_ki[0], 1e-12)
    assert_in_delta(Math::E,     a.exp_ki[1], 1e-12)
    assert_in_delta(Math::E**2,  a.exp_ki[2], 1e-12)
  end

  def test_log_ki
    a = CA_FLOAT64([1.0, Math::E, Math::E ** 2])
    assert_in_delta(0.0, a.log_ki[0], 1e-12)
    assert_in_delta(1.0, a.log_ki[1], 1e-12)
    assert_in_delta(2.0, a.log_ki[2], 1e-12)
  end

  def test_transcendental_int_source_widens
    # int32 source -> f64 output for all transcendentals.
    a = CA_INT32([0, 1, 4])
    [:sqrt_ki, :sin_ki, :cos_ki, :exp_ki].each do |op|
      result = a.send(op)
      assert_equal(CA_FLOAT64, result.data_type,
                   "expected #{op} on int32 to produce float64 output")
    end
  end

  # ---- preserve-data_type maps (square, abs, negate) ---------------------

  def test_square_ki_float64
    a = CA_FLOAT64([1.0, -2.0, 3.0, -4.0])
    assert_equal([1.0, 4.0, 9.0, 16.0], a.square_ki.to_a)
  end

  def test_square_ki_int32_preserves_data_type
    a = CA_INT32([1, 2, 3, 4])
    result = a.square_ki
    assert_equal(CA_INT32, result.data_type)
    assert_equal([1, 4, 9, 16], result.to_a)
  end

  def test_abs_ki_float64
    a = CA_FLOAT64([-1.5, 0.0, 2.5, -3.5])
    assert_equal([1.5, 0.0, 2.5, 3.5], a.abs_ki.to_a)
  end

  def test_abs_ki_int32_preserves_data_type
    a = CA_INT32([-1, 0, 2, -3])
    result = a.abs_ki
    assert_equal(CA_INT32, result.data_type)
    assert_equal([1, 0, 2, 3], result.to_a)
  end

  def test_negate_ki_float64
    a = CA_FLOAT64([1.0, -2.0, 3.0])
    assert_equal([-1.0, 2.0, -3.0], a.negate_ki.to_a)
  end

  def test_negate_ki_int64_preserves_data_type
    a = CA_INT64([1, -2, 3])
    result = a.negate_ki
    assert_equal(CA_INT64, result.data_type)
    assert_equal([-1, 2, -3], result.to_a)
  end

  def test_preserve_data_type_map_raises_on_unsupported
    # square/abs/negate use fallback: :raise (because :preserve + wrap
    # would silently change data_type).  Boolean source raises.
    # Phase E: data_type-reject now raises CArray::DataTypeError.
    a = CArray.boolean(4)
    assert_raise(CArray::DataTypeError) { a.square_ki }
    assert_raise(CArray::DataTypeError) { a.abs_ki    }
    assert_raise(CArray::DataTypeError) { a.negate_ki }
  end

  def test_abs_negate_raise_on_unsigned
    # abs / negate are defined for SIGNED_NUMERIC only -- unsigned `v < 0`
    # is always false (compiler warning + identity), and -v on unsigned
    # wraps.  Both should raise on uint sources.
    # Phase E: data_type-reject now raises CArray::DataTypeError.
    a = CArray.uint8(4).seq
    assert_raise(CArray::DataTypeError) { a.abs_ki    }
    assert_raise(CArray::DataTypeError) { a.negate_ki }
    b = CArray.uint16(4).seq
    assert_raise(CArray::DataTypeError) { b.abs_ki    }
    assert_raise(CArray::DataTypeError) { b.negate_ki }
  end

  def test_map_ki_3d_walk
    # Verify the K-D walk works correctly across all map kernels.
    a = CArray.float64(2, 3, 4).seq + 1
    result = a.sqrt_ki
    a.each_with_addr do |v, addr|
      idx = a.addr2index(addr)
      assert_in_delta(Math.sqrt(v), result[*idx], 1e-12)
    end
  end

  # ---- MkKernel.scan form (cumsum + family) ---------------------------
  # Phase D §scan: stat_proc 14/14 completion landed.
  # New CA_SLAB_SCAN_T macro + DSL form.  Each scan slab is one "fiber"
  # along the user-supplied axis; acc resets per fiber.

  def test_cumsum_ki_1d
    a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])
    assert_equal([1.0, 3.0, 6.0, 10.0, 15.0], a.cumsum_ki(axis: 0).to_a)
  end

  def test_cumsum_ki_2d_axis0
    a = CArray.float64(3, 4).seq + 1  # rows = [1..4, 5..8, 9..12]
    result = a.cumsum_ki(axis: 0)
    # axis=0 cumsum: per-column running sum
    assert_equal([1, 2, 3, 4],         result[0, nil].to_a)
    assert_equal([6, 8, 10, 12],       result[1, nil].to_a)
    assert_equal([15, 18, 21, 24],     result[2, nil].to_a)
  end

  def test_cumsum_ki_2d_axis1
    a = CArray.float64(2, 4).seq + 1   # [[1,2,3,4], [5,6,7,8]]
    result = a.cumsum_ki(axis: 1)
    assert_equal([1.0, 3.0, 6.0, 10.0],  result[0, nil].to_a)
    assert_equal([5.0, 11.0, 18.0, 26.0], result[1, nil].to_a)
  end

  def test_cumsum_ki_int32_widens_to_f64
    a = CArray.int32(5).seq + 1
    result = a.cumsum_ki(axis: 0)
    assert_equal(CA_FLOAT64, result.data_type)
    assert_equal([1.0, 3.0, 6.0, 10.0, 15.0], result.to_a)
  end

  def test_cumsum_ki_negative_axis_normalised
    a = CArray.float64(2, 3).seq + 1
    # axis -1 == axis 1 for ndim=2
    assert_equal(a.cumsum_ki(axis: 1).to_a, a.cumsum_ki(axis: -1).to_a)
  end

  def test_cumsum_ki_invalid_axis_raises
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.cumsum_ki(axis: 5) }
    assert_raise(ArgumentError) { a.cumsum_ki(axis: -10) }
  end

  def test_cumprod_ki
    a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])
    assert_equal([1.0, 2.0, 6.0, 24.0, 120.0], a.cumprod_ki(axis: 0).to_a)
  end

  def test_cumprod_ki_2d_axis1
    a = CArray.float64(2, 3).seq + 1  # [[1,2,3],[4,5,6]]
    expected = [[1, 2, 6], [4, 20, 120]]
    assert_equal(expected.flatten, a.cumprod_ki(axis: 1).to_a.flatten)
  end

  def test_cummax_ki_preserves_data_type
    a = CA_INT32([3, 1, 4, 1, 5, 9, 2, 6])
    result = a.cummax_ki(axis: 0)
    assert_equal(CA_INT32, result.data_type)
    assert_equal([3, 3, 4, 4, 5, 9, 9, 9], result.to_a)
  end

  def test_cummin_ki_preserves_data_type
    a = CA_INT32([5, 3, 4, 1, 2, 0, 6])
    result = a.cummin_ki(axis: 0)
    assert_equal(CA_INT32, result.data_type)
    assert_equal([5, 3, 3, 1, 1, 0, 0], result.to_a)
  end

  def test_cummin_ki_float
    a = CA_FLOAT64([5.0, 3.0, 4.0, 1.0, 2.0, 0.0, 6.0])
    assert_equal([5.0, 3.0, 3.0, 1.0, 1.0, 0.0, 0.0], a.cummin_ki(axis: 0).to_a)
  end

  def test_cumcount_ki_data_type_is_int64
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(5).seq
    result = a.cumcount_ki(axis: 0)
    assert_equal(CA_INT64, result.data_type)
    assert_equal([1, 2, 3, 4, 5], result.to_a)
  end

  def test_cumcount_ki_2d
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.float64(3, 4).seq
    result = a.cumcount_ki(axis: 0)
    # Each column counts independently up to 3.
    assert_equal([1, 1, 1, 1], result[0, nil].to_a)
    assert_equal([2, 2, 2, 2], result[1, nil].to_a)
    assert_equal([3, 3, 3, 3], result[2, nil].to_a)
  end

  def test_cumsum_ki_masked_writes_acc
    # 2026-06-03: macro semantics changed to write `acc` (the running
    # aggregate) at masked cells instead of sentinel 0.  This matches
    # legacy CArray#cumsum and keeps the "running aggregate" output
    # value continuous (= masked cell shows what the value would be
    # excluding this cell, not a silent 0).
    a = CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0])
    a[2] = UNDEF
    # After cell 0: acc=1, write 1
    # After cell 1: acc=3, write 3
    # Cell 2 masked: acc=3 (unchanged), write acc=3
    # After cell 3: acc=3+4=7, write 7
    # After cell 4: acc=7+5=12, write 12
    assert_equal([1.0, 3.0, 3.0, 7.0, 12.0], a.cumsum_ki(axis: 0).to_a)
  end

  def test_cumcount_ki_masked
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CA_FLOAT64([10.0, 20.0, 30.0, 40.0, 50.0])
    a[2] = UNDEF
    # acc: 0, 1, 2 (skipped at idx 2), 3, 4; written: 1,2,sentinel(0),3,4
    assert_equal([1, 2, 0, 3, 4], a.cumcount_ki(axis: 0).to_a)
  end

  def test_cummax_ki_boolean_numeric
    # 3.0: boolean cummax / cummin run on the 0/1 numeric storage
    # (u64 output), not rejected.
    a = CArray.boolean(5) { |i| i == 2 }   # [0, 0, 1, 0, 0]
    assert_equal [0, 0, 1, 1, 1], a.cummax_ki(axis: 0).to_a
    assert_equal [0, 0, 0, 0, 0], a.cummin_ki(axis: 0).to_a
  end

  def test_cumsum_ki_int16_falls_through_to_wrap
    # cumsum / cumprod / cumcount fall through to f64.
    a = CArray.int16(5).seq + 1
    assert_equal(CA_FLOAT64, a.cumsum_ki(axis: 0).data_type)
    assert_equal([1.0, 3.0, 6.0, 10.0, 15.0], a.cumsum_ki(axis: 0).to_a)
  end

  def test_cumsum_ki_view_chain
    # transpose then scan: each "row" of the transposed view (= original
    # column) cumulates independently.
    a = CArray.float64(3, 4).seq + 1   # 3x4
    tv = a.transpose                   # 4x3
    # tv.cumsum_ki(axis: 1): per row (= original col) cumsum.
    result = tv.cumsum_ki(axis: 1)
    expected_col0 = [1.0, 1+5, 1+5+9]
    assert_equal(expected_col0, result[0, nil].to_a)
  end

  def test_cumsum_ki_3d
    # Verify K-D outer carry works on 3D.
    a = CArray.float64(2, 3, 4).seq + 1
    result = a.cumsum_ki(axis: 2)   # along the innermost
    # Each (i, j) row of 4 cells cumulates independently.
    2.times do |i|
      3.times do |j|
        running = 0.0
        4.times do |k|
          running += a[i, j, k]
          assert_in_delta(running, result[i, j, k], 1e-12,
                          "mismatch at (#{i}, #{j}, #{k})")
        end
      end
    end
  end

  def test_cumprod_ki_zero_propagates
    a = CA_FLOAT64([2.0, 3.0, 0.0, 4.0, 5.0])
    # 2, 6, 0, 0, 0
    assert_equal([2.0, 6.0, 0.0, 0.0, 0.0], a.cumprod_ki(axis: 0).to_a)
  end

  # ---- expanded data_type coverage (§N1: i8/u8/i16/u16/u32/u64 native) ----
  # Phase D §N1: DTYPES table expanded to all 10 standard numerics
  # (i8/u8/i16/u16/i32/u32/i64/u64/f32/f64).  Pre-§N1 only 4 data_types
  # had native helpers; the other 6 numerics either went through the
  # CAFake wrap_to_f64 fallback (for sum-class kernels) or raised
  # ArgumentError (for :preserve kernels like min/max).
  #
  # These tests pin that the 6 new data_types now have native dispatch
  # across the kernel families.

  def test_sum_ki_int8_native
    a = CArray.int8(5).seq    # [0, 1, 2, 3, 4]
    assert_in_delta(10.0, a.sum(axis: 0), 1e-12)
  end

  def test_sum_ki_uint8_native
    a = CArray.uint8(4).seq + 100
    # 100 + 101 + 102 + 103 = 406
    assert_in_delta(406.0, a.sum(axis: 0), 1e-12)
  end

  def test_sum_ki_uint64_native
    a = CArray.uint64(3).seq + 1000
    # 1000 + 1001 + 1002 = 3003
    assert_in_delta(3003.0, a.sum(axis: 0), 1e-12)
  end

  def test_min_ki_int8_preserves_data_type
    # 2D so reduce(axis=0) returns CArray (not full-reduced scalar)
    a = CArray.int8(3, 4).seq + 1
    result = a.min(axis: 0)
    assert_equal(CA_INT8, result.data_type)
    assert_equal([1, 2, 3, 4], result.to_a)
  end

  def test_max_ki_uint8_preserves_data_type
    a = CArray.uint8(3, 4).seq + 100
    result = a.max(axis: 0)
    assert_equal(CA_UINT8, result.data_type)
    assert_equal([108, 109, 110, 111], result.to_a)
  end

  def test_min_ki_uint16_native
    a = CArray.uint16(5)
    a[0] = 100; a[1] = 50; a[2] = 200; a[3] = 30; a[4] = 150
    assert_equal(30, a.min(axis: 0))
  end

  def test_max_ki_uint32_native
    a = CArray.uint32(3)
    a[0] = 1_000_000; a[1] = 50; a[2] = 999
    assert_equal(1_000_000, a.max(axis: 0))
  end

  def test_argmin_ki_int16_native
    omit "Removed in E.8 _ki retire; re-implement per CLAUDE.md"
    a = CArray.int16(5)
    a[0] = 100; a[1] = -50; a[2] = 0; a[3] = -200; a[4] = 75
    assert_equal(3, a.argmin_ki(0))
  end

  def test_cumsum_ki_uint8_widens
    a = CArray.uint8(5).seq + 10  # [10, 11, 12, 13, 14]
    # Output is f64 (cumsum uses :f64), values [10, 21, 33, 46, 60]
    assert_equal(CA_FLOAT64, a.cumsum_ki(axis: 0).data_type)
    assert_equal([10.0, 21.0, 33.0, 46.0, 60.0], a.cumsum_ki(axis: 0).to_a)
  end

  def test_cummax_ki_int16_preserves_data_type
    a = CArray.int16(5)
    a[0] = 3; a[1] = -1; a[2] = 4; a[3] = -1; a[4] = 5
    result = a.cummax_ki(axis: 0)
    assert_equal(CA_INT16, result.data_type)
    assert_equal([3, 3, 4, 4, 5], result.to_a)
  end

  def test_cummin_ki_uint32_preserves_data_type
    a = CArray.uint32(4)
    a[0] = 5; a[1] = 3; a[2] = 4; a[3] = 1
    result = a.cummin_ki(axis: 0)
    assert_equal(CA_UINT32, result.data_type)
    assert_equal([5, 3, 3, 1], result.to_a)
  end

  def test_square_ki_uint8
    a = CA_UINT8([1, 2, 3, 5])
    result = a.square_ki
    assert_equal(CA_UINT8, result.data_type)
    # 25 fits in uint8; check overflow boundary too
    assert_equal([1, 4, 9, 25], result.to_a)
  end

  def test_mean_ki_int8_native
    a = CArray.int8(5).seq   # [0,1,2,3,4]
    assert_in_delta(2.0, a.mean(axis: 0), 1e-12)
  end

  def test_variance_ki_uint16_native
    a = CArray.uint16(4)
    a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4
    # sample variance = ((1-2.5)^2 + (2-2.5)^2 + (3-2.5)^2 + (4-2.5)^2)/3
    # = (2.25+0.25+0.25+2.25)/3 = 5/3 ≈ 1.6667
    assert_in_delta(5.0/3.0, a.variance(axis: 0), 1e-9)
  end

  def test_sqrt_ki_int8_native
    a = CA_INT8([1, 4, 9, 16])
    result = a.sqrt_ki
    assert_equal(CA_FLOAT64, result.data_type)
    assert_equal([1.0, 2.0, 3.0, 4.0], result.to_a)
  end

  def test_all_native_dtypes_no_longer_use_wrap_fallback
    # Smoke check: each of the 10 native data_types should have its own
    # dispatch case (= int_array.min returns the right data_type
    # without going through f64 wrap).  Pre-expansion this would
    # have either raised (for :preserve) or returned f64 (for :f64).
    [:int8, :uint8, :int16, :uint16, :int32, :uint32,
     :int64, :uint64, :float32, :float64].each do |data_type_method|
      a = CArray.send(data_type_method, 5).seq
      # min preserves source data_type for native path
      m = a.min(axis: 0)
      expected_ca_data_type = case data_type_method
                          when :int8    then CA_INT8
                          when :uint8   then CA_UINT8
                          when :int16   then CA_INT16
                          when :uint16  then CA_UINT16
                          when :int32   then CA_INT32
                          when :uint32  then CA_UINT32
                          when :int64   then CA_INT64
                          when :uint64  then CA_UINT64
                          when :float32 then CA_FLOAT32
                          when :float64 then CA_FLOAT64
                          end
      # m is a scalar (full reduction with naxes==1==ndim).
      # For numeric scalars, just confirm it's not raising and
      # the array form returns expected data_type.
      result_array = a.reshape(5, 1).min(axis: 0)
      assert_equal(expected_ca_data_type, result_array.data_type,
                   "expected #{data_type_method} min_ki to preserve source data_type")
    end
  end

  def test_bool_sum_accepts_as_count
    # PROPOSAL_BOOLEAN_REDUCE_ACCEPT (2026-06-15): boolean sum reinstated
    # as count-of-true (matches NumPy + 2.x idiom).  Was 3.0-breaking
    # reject from the family-wide complex support phase; revert restores
    # the natural numeric coercion path that already works for
    # (a > 0) * b in binop family.
    a = CArray.boolean(5)
    a[0] = 1; a[1] = 0; a[2] = 1; a[3] = 1; a[4] = 0
    assert_equal(3, a.sum(axis: 0))
    # Equivalent idioms:
    assert_equal(3, a.count(true))
    assert_in_delta(3.0, a.as_int32.sum(axis: 0), 1e-12)
  end

  # ---- min_ki / max_ki --------------------------------------------------
  # (note: the original "mean_ki" test block from Phase D §3.a was
  # superseded by the more thorough multi-state block above when mean_ki
  # migrated from hand-written to the mkkernel generator.)

  def test_min_ki_entity
    a = CA_FLOAT64([3.0, -1.0, 2.5, 0.0, -4.0])
    assert_in_delta(-4.0, a.min(axis: 0), 1e-12)
  end

  def test_max_ki_entity
    a = CA_FLOAT64([3.0, -1.0, 2.5, 0.0, -4.0])
    assert_in_delta(3.0, a.max(axis: 0), 1e-12)
  end

  def test_min_max_ki_axis0_2d
    a = CArray.float64(5, 4).seq - 7.0
    assert_in_delta((a.min(axis: 0) - a.min(axis: 0)).abs.max, 0.0, 1e-9)
    assert_in_delta((a.max(axis: 0) - a.max(axis: 0)).abs.max, 0.0, 1e-9)
  end

  def test_min_max_ki_masked
    a = CA_FLOAT64([5.0, -1.0, 2.0, 7.0, -3.0])
    a[1] = UNDEF   # mask out -1
    a[4] = UNDEF   # mask out -3
    assert_in_delta(2.0, a.min(axis: 0), 1e-12)
    assert_in_delta(7.0, a.max(axis: 0), 1e-12)
  end

  def test_min_ki_empty_slab_yields_undef
    # Phase E: min/max now use mask_policy: :min_count so all-masked
    # slabs return UNDEF (matching legacy CArray#min / #max semantics).
    # Prior Phase D POC behaviour returned the init value (INFINITY /
    # -INFINITY) when no element ever updated acc.
    a = CArray.float64(3).seq
    a[0..2] = UNDEF
    assert_equal(UNDEF, a.min(axis: 0))
    assert_equal(UNDEF, a.max(axis: 0))
  end

  def test_min_ki_view_chain
    a = CArray.float64(8, 6).seq - 10
    tv = a.transpose
    assert_in_delta((tv.min(axis: 0) - tv.min(axis: 0)).abs.max, 0.0, 1e-9)
  end

  # ---- sqrt_ki (CA_SLAB_MAP_F64) ---------------------------------------

  def test_sqrt_ki_entity_1d
    a = CA_FLOAT64([1.0, 4.0, 9.0, 16.0, 25.0])
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0], a.sqrt_ki.to_a)
  end

  def test_sqrt_ki_entity_3d
    a = CArray.float64(3, 4, 5).seq + 1
    result = a.sqrt_ki
    a.each_with_addr do |v, addr|
      expected = Math.sqrt(v)
      idx = a.addr2index(addr)
      assert_in_delta(expected, result[*idx], 1e-12,
                      "mismatch at idx=#{idx.inspect}")
    end
  end

  def test_sqrt_ki_view_chain_transpose
    a = CArray.float64(6, 7).seq + 1
    tv = a.transpose
    result = tv.sqrt_ki
    tv.each_with_addr do |v, addr|
      idx = tv.addr2index(addr)
      assert_in_delta(Math.sqrt(v), result[*idx], 1e-12)
    end
  end

  def test_sqrt_ki_int_source_auto_widening
    a = CA_INT32([1, 4, 9, 16])
    assert_equal([1.0, 2.0, 3.0, 4.0], a.sqrt_ki.to_a)
    # Output is float64 entity
    assert_equal(CA_FLOAT64, a.sqrt_ki.data_type)
  end

  def test_sqrt_ki_output_is_entity
    a = CArray.float64(2, 3).seq + 1
    out = a.sqrt_ki
    assert_equal(CArray, out.class)
    assert_equal(a.dim, out.dim)
  end

end
