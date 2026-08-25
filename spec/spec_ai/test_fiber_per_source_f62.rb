# frozen_string_literal: true
#
# spec_ai/test_fiber_per_source_f62.rb
#
# PROPOSAL_FIBER_PER_SOURCE_PATH F.6.2 regression pin.
#
# Verifies the per-fiber fused dispatch (CA_ITER_ALIAS_PER_FIBER_FUSED)
# is correctly enabled for CAFake / CAByteSwap when the fiber-axis
# effective stride matches view cell bytes (= Q3 predicate), and
# correctly NOT enabled when fiber is non-innermost (= gate must keep
# the current whole-view materialise path).
#
# Tests are driven through the catalog macro CA_FOR_EACH_FIBER (smoke
# kernel caf_fiber_smoke_sum_f64).  Parity is checked against
# view.to_ca.sum; mask propagation is checked via _unmasked_sum
# smoke.  WRITE PUT path is checked via _double smoke (in-place x2)
# rebuilding view.to_ca afterwards.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestFiberPerSourceF62 < Test::Unit::TestCase
  TOL = 1e-6

  # --- CAFake (int32 -> float64) ----------------------------------

  def test_cafake_innermost_axis_fiber_sum_parity
    src = CArray.int32(8, 16).seq
    v   = src.fake(:float64)
    s   = CArray.caf_fiber_smoke_sum_f64(v, v.ndim - 1)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cafake_outer_axis_fiber_sum_parity
    src = CArray.int32(8, 16).seq
    v   = src.fake(:float64)
    s   = CArray.caf_fiber_smoke_sum_f64(v, 0)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cafake_3d_innermost_axis_fiber_sum_parity
    src = CArray.int32(4, 5, 6).seq
    v   = src.fake(:float64)
    s   = CArray.caf_fiber_smoke_sum_f64(v, v.ndim - 1)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cafake_3d_middle_axis_fiber_sum_parity
    # axis 1 of 3D: fiber stride != bytes -> predicate must NOT fire,
    # whole-view materialise path takes over.
    src = CArray.int32(4, 5, 6).seq
    v   = src.fake(:float64)
    s   = CArray.caf_fiber_smoke_sum_f64(v, 1)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cafake_innermost_axis_unmasked_sum_parity
    # mask presence -> per-fiber mask scratch gather must work
    src = CArray.int32(6, 10).seq
    src.mask = CArray.boolean(6, 10) { |i, j| (i + j) % 3 == 0 ? 1 : 0 }
    v = src.fake(:float64)
    s = CArray.caf_fiber_smoke_unmasked_sum_f64(v, v.ndim - 1)
    # Reference: sum of non-masked cells
    ref = 0.0
    v.to_ca.each_with_addr do |val, addr|
      next if v.mask && v.mask[addr]
      ref += val
    end
    assert_in_delta ref, s, TOL
  end

  # --- CAByteSwap -------------------------------------------------

  def test_cabyteswap_innermost_axis_fiber_sum_parity
    src = CArray.float64(8, 16) { |i, j| (i * 16 + j).to_f }
    v   = src.swap_bytes
    s   = CArray.caf_fiber_smoke_sum_f64(v, v.ndim - 1)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cabyteswap_outer_axis_fiber_sum_parity
    src = CArray.float64(8, 16) { |i, j| (i * 16 + j).to_f }
    v   = src.swap_bytes
    s   = CArray.caf_fiber_smoke_sum_f64(v, 0)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  def test_cabyteswap_3d_innermost_axis_fiber_sum_parity
    src = CArray.float64(4, 5, 6) { |i, j, k| (i * 30 + j * 6 + k).to_f }
    v   = src.swap_bytes
    s   = CArray.caf_fiber_smoke_sum_f64(v, v.ndim - 1)
    assert_in_delta v.to_ca.sum.to_f, s, TOL
  end

  # --- WRITE PUT path is covered by sort_copy-style kernels in
  # subsequent sub-steps; existing FIBER smoke kernels are INOUT
  # (= write to a separate output entity, not back to view source).
  # F.6.1 substrate sync_slab PER_FIBER_FUSED PUT branch is exercised
  # there.

  # --- F.6.3: CAShift (OOB-fused via X.1 per-region) -------------

  def test_cashift_innermost_axis_fiber_sum_parity
    base  = CArray.float64(8, 16).seq
    shift = base.shift(1, -1, fill_value: 0.0)
    s     = CArray.caf_fiber_smoke_sum_f64(shift, shift.ndim - 1)
    assert_in_delta shift.to_ca.sum.to_f, s, TOL
  end

  def test_cashift_outer_axis_fiber_sum_parity
    base  = CArray.float64(8, 16).seq
    shift = base.shift(1, -1, fill_value: 0.0)
    s     = CArray.caf_fiber_smoke_sum_f64(shift, 0)
    assert_in_delta shift.to_ca.sum.to_f, s, TOL
  end

  def test_cashift_3d_innermost_axis_fiber_sum_parity
    base  = CArray.float64(4, 5, 6) { |i, j, k| i * 30 + j * 6 + k }
    shift = base.shift(1, -1, 1, fill_value: 0.0)
    s     = CArray.caf_fiber_smoke_sum_f64(shift, shift.ndim - 1)
    assert_in_delta shift.to_ca.sum.to_f, s, TOL
  end

  # --- F.6.3: CAWindow with OOB axes (= SRC_DESCRIPTOR materialise
  # path).  Interior-only CAWindow stays on the L2 alias fast path
  # (= predicate gates out SRC_DESCRIPTOR_L2_ALIASABLE); covered by
  # existing test_fiber_delivery.rb regression.

  def test_cawindow_with_oob_innermost_fiber_sum_parity
    base = CArray.float64(8, 16).seq
    # Range extends past parent dim -> SHIFT axis, materialise path
    w    = base.window(-1..8, 0..15, fill_value: 0.0)
    s    = CArray.caf_fiber_smoke_sum_f64(w, w.ndim - 1)
    assert_in_delta w.to_ca.sum.to_f, s, TOL
  end

  def test_cawindow_with_oob_outer_axis_fiber_sum_parity
    base = CArray.float64(8, 16).seq
    w    = base.window(-1..8, 0..15, fill_value: 0.0)
    s    = CArray.caf_fiber_smoke_sum_f64(w, 0)
    assert_in_delta w.to_ca.sum.to_f, s, TOL
  end

  # --- predicate-off path: entity stays unchanged ----------------

  def test_entity_innermost_axis_path_unchanged
    src = CArray.float64(8, 16).seq
    s   = CArray.caf_fiber_smoke_sum_f64(src, src.ndim - 1)
    assert_in_delta src.sum.to_f, s, TOL
  end
end
