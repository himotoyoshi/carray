# frozen_string_literal: true
#
# spec_ai/test_fiber_delivery.rb
#
# PROPOSAL_FIBER_DELIVERY F.3 — catalog macro test pin.
#
# Verifies the 4-form catalog (CA_FOR_EACH_FIBER / _INOUT / _MASKED /
# _INOUT_MASKED, F.2) delivers contig data + mask + output for the
# matrix of source kinds × axis positions × R/W × mask presence.
#
# Source kinds (= 14 per proposal §2.1, abbreviated below for testing
# practicality — we drive each form against entity, CAStride family,
# representative SRC_DESCRIPTOR (CSA / CAGrid / CASelect / CAWindow /
# CAShift), and SRC_ATTACH (CAFake / CAByteSwap).  CAMapping,
# CABitfield, CABitarray, CAReduce, CAUnboundRepeat coverage rides on
# the broader spec_ai/test_t1_step9_src_attach.rb regression set since
# they go through the same engine paths).
#
# Axis position coverage: every test exercises BOTH innermost-axis
# (= alias fast path, slab_strides[0] == bytes) and non-innermost-axis
# (= per-fiber gather, slab_strides[0] != bytes) so the F.1a engine
# extension is fired in production.
#
# Smoke kernels driven: caf_fiber_smoke_{sum,double,unmasked_sum,
# zero_masked}_f64 (registered in Init_ca_kernel_iterator, F.2).
#
# Doc: devel/PROPOSAL_FIBER_DELIVERY.md §7 DoD.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestFiberDelivery < Test::Unit::TestCase

  TOL = 1e-9

  def sum_excluding_masked(ca)
    s = 0.0
    ca.each_with_addr do |v, addr|
      next if ca.has_mask? && ca.mask[addr]
      s += v
    end
    s
  end

  # ======================================================================
  # form 1 — CA_FOR_EACH_FIBER (NO_MASK, single input, R/W)
  # ======================================================================
  # caf_fiber_smoke_sum_f64 takes a fiber, sums it, accumulates total.
  # Total across all fibers must equal full-array sum regardless of axis.

  # --- entity ---

  def test_form1_entity_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    assert_in_delta a.sum.to_f,
                    CArray.caf_fiber_smoke_sum_f64(a, 1), TOL
  end

  def test_form1_entity_non_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    assert_in_delta a.sum.to_f,
                    CArray.caf_fiber_smoke_sum_f64(a, 0), TOL
  end

  def test_form1_entity_3d_each_axis
    a = CArray.float64(2, 3, 4) { |i,j,k| i*100 + j*10 + k }
    expected = a.sum.to_f
    [0, 1, 2].each do |ax|
      assert_in_delta expected,
                      CArray.caf_fiber_smoke_sum_f64(a, ax), TOL,
                      "axis=#{ax}"
    end
  end

  # --- CAStride family ---

  def test_form1_transpose_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    v = a.transpose # shape (4, 3), non-contig CAStride
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "transpose axis=#{ax}"
    end
  end

  def test_form1_block_slice
    a = CArray.float64(5, 6) { |i,j| i*6 + j }
    v = a[1..3, 1..4] # CABlock, 3x4
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "block axis=#{ax}"
    end
  end

  # --- SRC_DESCRIPTOR ---

  def test_form1_csa
    a = CArray.float64(4, 5) { |i,j| i*5 + j }
    mask = CArray.boolean(4) { |i| i.even? }
    v = a[mask, nil] # CSA, shape (2, 5)
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "csa axis=#{ax}"
    end
  end

  def test_form1_cagrid
    a = CArray.float64(5, 6) { |i,j| i*6 + j }
    idx = CArray.int32(3).tap { |x| x[] = [0, 2, 4] }
    v = a.grid(idx, nil) # CAGrid, (3, 6)
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "cagrid axis=#{ax}"
    end
  end

  def test_form1_caselect_1d
    a = CArray.float64(8).seq
    mask = CArray.boolean(8) { |i| i.even? }
    v = a[mask] # CASelect, shape (4,)
    assert_in_delta v.sum.to_f,
                    CArray.caf_fiber_smoke_sum_f64(v, 0), TOL
  end

  def test_form1_window_interior
    a = CArray.float64(5, 6) { |i,j| i*6 + j }
    v = a.window(1..3, 1..4) # CAWindow, interior 3x4
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "window axis=#{ax}"
    end
  end

  def test_form1_shift_no_oob
    a = CArray.float64(5, 6) { |i,j| i*6 + j }
    v = a.shift(0, 0, fill_value: 0.0) # CAShift but no actual shift
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "shift axis=#{ax}"
    end
  end

  # --- SRC_ATTACH ---

  def test_form1_cafake
    a = CArray.int32(3, 4) { |i,j| i*4 + j }
    v = a.fake(CA_FLOAT64)
    [0, 1].each do |ax|
      assert_in_delta v.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "fake axis=#{ax}"
    end
  end

  def test_form1_cabyteswap
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    v = a.swap_bytes.swap_bytes # CAByteSwap chain; values restored
    [0, 1].each do |ax|
      assert_in_delta a.sum.to_f,
                      CArray.caf_fiber_smoke_sum_f64(v, ax), TOL,
                      "byteswap axis=#{ax}"
    end
  end

  # ======================================================================
  # form 2 — CA_FOR_EACH_FIBER_INOUT (NO_MASK, write * 2)
  # ======================================================================

  def test_form2_entity_innermost_doubles
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    out = CArray.caf_fiber_smoke_double_f64(a, 1)
    assert_equal (a * 2.0).to_a, out.to_a
  end

  def test_form2_entity_non_innermost_doubles
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    out = CArray.caf_fiber_smoke_double_f64(a, 0)
    assert_equal (a * 2.0).to_a, out.to_a
  end

  def test_form2_transpose_both_axes
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    v = a.transpose
    [0, 1].each do |ax|
      out = CArray.caf_fiber_smoke_double_f64(v, ax)
      assert_equal (v * 2.0).to_a, out.to_a, "transpose axis=#{ax}"
    end
  end

  def test_form2_3d_each_axis
    a = CArray.float64(2, 3, 4) { |i,j,k| i*100 + j*10 + k }
    [0, 1, 2].each do |ax|
      out = CArray.caf_fiber_smoke_double_f64(a, ax)
      assert_equal (a * 2.0).to_a, out.to_a, "axis=#{ax}"
    end
  end

  def test_form2_block_slice_both_axes
    a = CArray.float64(5, 6) { |i,j| i*6 + j }
    v = a[1..3, 1..4]
    [0, 1].each do |ax|
      out = CArray.caf_fiber_smoke_double_f64(v, ax)
      assert_equal (v * 2.0).to_a, (out).to_a, "block axis=#{ax}"
    end
  end

  # ======================================================================
  # form 3 — CA_FOR_EACH_FIBER_MASKED (single, mask-aware sum)
  # ======================================================================

  def test_form3_entity_no_mask
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    [0, 1].each do |ax|
      assert_in_delta a.sum.to_f,
                      CArray.caf_fiber_smoke_unmasked_sum_f64(a, ax), TOL,
                      "no-mask axis=#{ax}"
    end
  end

  def test_form3_entity_with_mask_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    expected = sum_excluding_masked(a)
    assert_in_delta expected,
                    CArray.caf_fiber_smoke_unmasked_sum_f64(a, 1), TOL
  end

  def test_form3_entity_with_mask_non_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    a[2, 0] = UNDEF
    expected = sum_excluding_masked(a)
    # axis=0 fires the non-innermost mask gather path (mask_step != 1)
    assert_in_delta expected,
                    CArray.caf_fiber_smoke_unmasked_sum_f64(a, 0), TOL
  end

  def test_form3_3d_with_mask_each_axis
    a = CArray.float64(2, 3, 4) { |i,j,k| i*100 + j*10 + k }
    a[0, 1, 2] = UNDEF
    a[1, 2, 0] = UNDEF
    expected = sum_excluding_masked(a)
    [0, 1, 2].each do |ax|
      assert_in_delta expected,
                      CArray.caf_fiber_smoke_unmasked_sum_f64(a, ax), TOL,
                      "axis=#{ax}"
    end
  end

  def test_form3_transpose_with_mask
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    v = a.transpose
    expected = sum_excluding_masked(v)
    [0, 1].each do |ax|
      assert_in_delta expected,
                      CArray.caf_fiber_smoke_unmasked_sum_f64(v, ax), TOL,
                      "transpose+mask axis=#{ax}"
    end
  end

  # ======================================================================
  # form 4 — CA_FOR_EACH_FIBER_INOUT_MASKED (zero out masked)
  # ======================================================================

  def test_form4_entity_no_mask_passthrough
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    [0, 1].each do |ax|
      out = CArray.caf_fiber_smoke_zero_masked_f64(a, ax)
      assert_equal (a).to_a, (out).to_a, "no-mask axis=#{ax}"
    end
  end

  def test_form4_entity_with_mask_innermost
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    out = CArray.caf_fiber_smoke_zero_masked_f64(a, 1)
    expected = a.strip_mask(0.0)
    expected[1, 2] = 0.0
    assert_equal (expected).to_a, (out).to_a
  end

  def test_form4_entity_with_mask_non_innermost
    # Exercises both mask gather (non-innermost) AND data scatter (output
    # has non-innermost fiber → write through fiber_data_scratch).
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    a[2, 0] = UNDEF
    out = CArray.caf_fiber_smoke_zero_masked_f64(a, 0)
    expected = a.strip_mask(0.0)
    expected[1, 2] = 0.0
    expected[2, 0] = 0.0
    assert_equal (expected).to_a, (out).to_a
  end

  def test_form4_transpose_with_mask
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[1, 2] = UNDEF
    v = a.transpose
    expected = v.strip_mask(0.0)
    expected[2, 1] = 0.0 # transposed mask position
    [0, 1].each do |ax|
      out = CArray.caf_fiber_smoke_zero_masked_f64(v, ax)
      assert_equal (expected).to_a, (out).to_a, "axis=#{ax}"
    end
  end

  # ======================================================================
  # Edge cases
  # ======================================================================

  def test_form1_1d_only_axis_works
    a = CArray.float64(8).seq
    assert_in_delta a.sum.to_f,
                    CArray.caf_fiber_smoke_sum_f64(a, 0), TOL
  end

  def test_form2_1d_only_axis_doubles
    a = CArray.float64(8).seq
    out = CArray.caf_fiber_smoke_double_f64(a, 0)
    assert_equal (a * 2.0).to_a, out.to_a
  end

  def test_form3_no_mask_source_m_is_null
    # m == NULL case: form 3 kernel checks `!m` first; no-mask source
    # routes through that branch.  Must equal full sum.
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    assert_in_delta a.sum.to_f,
                    CArray.caf_fiber_smoke_unmasked_sum_f64(a, 0), TOL
  end

  def test_form4_all_masked_fiber
    # Entire fiber masked: output should be all zeros for that fiber.
    a = CArray.float64(3, 4) { |i,j| i*4 + j }
    a[0, nil] = UNDEF # mask out row 0 entirely
    out = CArray.caf_fiber_smoke_zero_masked_f64(a, 1)
    assert_equal 0.0, out[0, 0]
    assert_equal 0.0, out[0, 3]
    # Other rows preserved
    assert_equal a[1, 1].to_f, out[1, 1].to_f
  end

  # NOTE: INOUT shape-mismatch reject (rev4 §2.3) is enforced by the
  # macro's inner for-condition (ndim + elements + dim[axis] equality
  # check).  The Ruby-callable smoke kernels here always size output
  # via rb_ca_template(src) so shape mismatch is unreachable from this
  # surface.  Direct C kernels written against the catalog macros that
  # accept arbitrary `dst` should add their own shape validation if
  # needed, and the macro's runtime equality check is the last line of
  # defense.  Coverage of the runtime check itself belongs in a future
  # dedicated C smoke that constructs mismatched (src, dst) pairs.
end
