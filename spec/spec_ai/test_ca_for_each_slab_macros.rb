# frozen_string_literal: true
#
# spec_ai/test_ca_for_each_slab_macros.rb
#
# Phase C C.3: CA_FOR_EACH_SLAB / CA_FOR_EACH_SLAB_INOUT macro
# behavioural pin via the caf_smoke_* C surfaces.
#
# The macros expand to a for/for nest that wraps init_l2 →
# next_slab_axes loop → sync_slab (after each iter) → finish
# (on natural exit).  Author code becomes a single block scope
# carrying the kernel body.  This test validates byte parity
# of macro-expanded kernels vs the reference CArray operations.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestCAForEachSlabMacros < Test::Unit::TestCase

  def assert_close(expected, actual, msg = nil)
    if expected.is_a?(CArray) || expected.is_a?(CScalar)
      assert_in_delta(0.0, (expected - actual).abs.max, 1e-9, msg)
    else
      assert_in_delta(expected, actual, 1e-9, msg)
    end
  end

  # ---- CA_FOR_EACH_SLAB: reduction kernel ------------------------------

  def test_caf_sum_innermost_axis_entity
    a = CArray.float64(3, 4, 5).seq
    assert_close(a.sum(axis: 2), CArray.caf_smoke_sum_f64(a, 2))
  end

  def test_caf_sum_outer_axis_entity
    # slab on axis 0 → outer-only walk, single-element slab per outer
    a = CArray.float64(3, 4, 5).seq
    assert_close(a.sum(axis: 0), CArray.caf_smoke_sum_f64(a, 0))
  end

  def test_caf_sum_multi_axis_entity
    a = CArray.float64(3, 4, 5).seq
    assert_close(a.sum(axis: [0, 2]), CArray.caf_smoke_sum_f64(a, 0, 2))
  end

  def test_caf_sum_full_reduction_entity
    a = CArray.float64(3, 4, 5).seq
    assert_close(a.sum.to_f, CArray.caf_smoke_sum_f64(a, 0, 1, 2))
  end

  def test_caf_sum_with_mask
    a = CArray.float64(3, 4).seq
    a[0, 0] = UNDEF
    a[2, 3] = UNDEF
    assert_close(a.sum(axis: 1), CArray.caf_smoke_sum_f64(a, 1))
    assert_close(a.sum.to_f, CArray.caf_smoke_sum_f64(a, 0, 1))
  end

  # ---- CA_FOR_EACH_SLAB on descriptor views (Phase B + C T3) -----------

  def test_caf_sum_on_csa_phase_b_alias
    # all-STRIDE slab on CSA → Phase B alias path
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5); [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum(axis: 2),    CArray.caf_smoke_sum_f64(csa, 2))
    assert_close(csa.sum(axis: [1, 2]), CArray.caf_smoke_sum_f64(csa, 1, 2))
  end

  def test_caf_sum_on_csa_t3_hoist
    # INDEX slab + innermost STRIDE → T3 HOIST specialised path
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5); [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum(axis: [0, 2]), CArray.caf_smoke_sum_f64(csa, 0, 2))
    assert_close(csa.sum.to_f,  CArray.caf_smoke_sum_f64(csa, 0, 1, 2))
  end

  def test_caf_sum_on_csa_t3_fallback
    # INDEX slab innermost → T3 (A) fallback
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5); [1, 3].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum(axis: 0), CArray.caf_smoke_sum_f64(csa, 0))
  end

  def test_caf_sum_on_cawindow_shift_slab
    a = CArray.float64(5, 4, 3).seq
    w = a.window(-1..3, nil, nil, fill_value: 0.0)
    assert_close(w.sum(axis: 0),    CArray.caf_smoke_sum_f64(w, 0))
    assert_close(w.sum(axis: [0, 2]), CArray.caf_smoke_sum_f64(w, 0, 2))
  end

  # ---- CA_FOR_EACH_SLAB_INOUT: map kernel ------------------------------

  def test_caf_inout_double_1d
    a = CArray.float64(8).seq
    got = CArray.caf_smoke_double_f64(a)
    assert_close(a * 2, got)
  end

  def test_caf_inout_double_2d
    a = CArray.float64(3, 4).seq
    got = CArray.caf_smoke_double_f64(a)
    assert_close(a * 2, got)
  end

  def test_caf_inout_double_3d
    a = CArray.float64(2, 3, 4).seq
    got = CArray.caf_smoke_double_f64(a)
    assert_close(a * 2, got)
  end

  # ---- macro mechanical pins -------------------------------------------

  def test_caf_lifecycle_no_leak
    # Repeat the macro many times to surface any lifecycle bug
    # (= scratch_ptr not freed, parent not detached, outer_idx not freed).
    a = CArray.float64(10, 10).seq
    100.times do
      assert_close(a.sum(axis: 1), CArray.caf_smoke_sum_f64(a, 1))
    end
  end

  def test_caf_inout_lifecycle_no_leak
    a = CArray.float64(20, 30).seq
    100.times do
      got = CArray.caf_smoke_double_f64(a)
      assert_close(a * 2, got)
    end
  end

  def test_caf_inout_lifecycle_with_t3_input
    # INOUT macro on descriptor view as input — input is CSA, output is
    # fresh entity.  In iter takes Phase B alias path (all-STRIDE slab
    # = innermost axis), out iter takes Phase A entity path.
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5); [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    # caf_smoke_double_f64 doubles each element on innermost slab axis
    expected = csa.to_ca * 2
    got = CArray.caf_smoke_double_f64(csa)
    assert_close(expected, got)
  end
end
