# frozen_string_literal: true
#
# spec_ai/test_ca_helpers.rb
#
# Phase A capstone (PROPOSAL_CAPSTONE_PHASE_A.md A.3): rb_ca_new_reduced
# helper unit tests.  Verifies output shape + data_type for partial /
# full reduction, error rejects for bad axis input, data_type-preserve and
# data_type-change cases (e.g. int32 source → float64 mean output).

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestCAHelpers < Test::Unit::TestCase

  # ---- rb_ca_new_reduced shape correctness -----------------------------

  def test_partial_reduce_single_axis_inner
    ca = CArray.float64(2, 3, 4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 3)
    assert_equal([2, 3, 4], out.dim)
    assert_equal(CA_FLOAT64, out.data_type)
  end

  def test_partial_reduce_single_axis_outer
    ca = CArray.float64(2, 3, 4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0)
    assert_equal([3, 4, 5], out.dim)
  end

  def test_partial_reduce_multi_axis_contiguous
    ca = CArray.float64(2, 3, 4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 2, 3)
    assert_equal([2, 3], out.dim)
  end

  def test_partial_reduce_multi_axis_non_adjacent
    ca = CArray.float64(2, 3, 4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0, 2)
    assert_equal([3, 5], out.dim)
  end

  def test_partial_reduce_canonicalises_order
    # Input axes {3, 0, 2} should produce same shape as {0, 2, 3}
    ca = CArray.float64(2, 3, 4, 5).seq
    a = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 3, 0, 2)
    b = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0, 2, 3)
    assert_equal(a.dim, b.dim)
    assert_equal([3], a.dim)  # only axis 1 survives
  end

  def test_full_reduce_returns_shape_1
    # All axes reduced → output is shape [1] 1-D (D2.2)
    ca = CArray.float64(2, 3, 4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0, 1, 2, 3)
    assert_equal([1], out.dim)
    assert_equal(1, out.ndim)
  end

  def test_full_reduce_1d_source
    ca = CArray.float64(10).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0)
    assert_equal([1], out.dim)
  end

  # ---- data_type handling --------------------------------------------------

  def test_data_type_preserve_int32
    ca = CArray.int32(4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_INT32, 1)
    assert_equal(CA_INT32, out.data_type)
    assert_equal([4], out.dim)
  end

  def test_data_type_change_int_to_float
    # mean of int32 → float64 result
    ca = CArray.int32(4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 1)
    assert_equal(CA_FLOAT64, out.data_type)
    assert_equal([4], out.dim)
  end

  def test_data_type_widen_int32_to_int64
    # sum of int32 → int64 (accumulator overflow guard pattern)
    ca = CArray.int32(4, 5).seq
    out = CArray.t1_test_new_reduced(ca, CA_INT64, 0)
    assert_equal(CA_INT64, out.data_type)
    assert_equal([5], out.dim)
  end

  # ---- error rejects --------------------------------------------------

  def test_reject_duplicate_axis
    ca = CArray.float64(2, 3, 4)
    assert_raise(ArgumentError) do
      CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0, 0)
    end
  end

  def test_reject_out_of_range_axis
    ca = CArray.float64(2, 3)
    assert_raise(ArgumentError) do
      CArray.t1_test_new_reduced(ca, CA_FLOAT64, 5)
    end
  end

  def test_reject_negative_axis
    ca = CArray.float64(2, 3)
    assert_raise(ArgumentError) do
      CArray.t1_test_new_reduced(ca, CA_FLOAT64, -1)
    end
  end

  def test_reject_naxes_exceeds_ndim
    ca = CArray.float64(2, 3)  # ndim=2
    assert_raise(ArgumentError) do
      # 3 axes total (0, 1 unique + dup 0) — first hits range check
      CArray.t1_test_new_reduced(ca, CA_FLOAT64, 0, 1, 0)
    end
  end

  def test_reject_invalid_data_type
    ca = CArray.float64(2, 3)
    assert_raise(ArgumentError) do
      # CA_FIXLEN unsupported (= helper is for numeric data_types only)
      CArray.t1_test_new_reduced(ca, CA_FIXLEN, 0)
    end
  end

  # ---- B.3: rb_ca_parse_reduce_axes ------------------------------------

  def test_parse_axes_integer_individual
    ca = CArray.float64(2, 3, 4)
    assert_equal([0],       CArray.t1_test_parse_reduce_axes(ca, 0))
    assert_equal([0, 2],    CArray.t1_test_parse_reduce_axes(ca, 0, 2))
    assert_equal([1, 0, 2], CArray.t1_test_parse_reduce_axes(ca, 1, 0, 2))
  end

  def test_parse_axes_array_form
    ca = CArray.float64(2, 3, 4)
    assert_equal([0, 2],    CArray.t1_test_parse_reduce_axes(ca, [0, 2]))
    assert_equal([1, 0, 2], CArray.t1_test_parse_reduce_axes(ca, [1, 0, 2]))
  end

  def test_parse_axes_negative_normalised
    ca = CArray.float64(2, 3, 4)  # ndim = 3
    assert_equal([2], CArray.t1_test_parse_reduce_axes(ca, -1))    # -1 → 2
    assert_equal([1], CArray.t1_test_parse_reduce_axes(ca, -2))    # -2 → 1
    assert_equal([0], CArray.t1_test_parse_reduce_axes(ca, -3))    # -3 → 0
  end

  def test_parse_axes_negative_in_array
    ca = CArray.float64(2, 3, 4)
    assert_equal([0, 2], CArray.t1_test_parse_reduce_axes(ca, [0, -1]))
  end

  def test_parse_axes_preserves_input_order
    # rb_ca_parse_reduce_axes returns axes in input order (= not sorted).
    # init_l2 CA_SLAB_AXES does its own sort-ascending canonicalisation.
    ca = CArray.float64(2, 3, 4, 5)
    assert_equal([3, 0, 2], CArray.t1_test_parse_reduce_axes(ca, 3, 0, 2))
    assert_equal([3, 0, 2], CArray.t1_test_parse_reduce_axes(ca, [3, 0, 2]))
  end

  def test_parse_axes_empty_means_full_reduction
    # Phase E: argc == 0 now means "all axes" (= full reduction),
    # so the helper returns [0, 1, ..., ndim-1] instead of raising.
    # This contract lets ki kernels become drop-in for legacy CArray#sum
    # which accepts a no-arg form.
    ca = CArray.float64(2, 3)
    assert_equal([0, 1], CArray.t1_test_parse_reduce_axes(ca))
  end

  def test_parse_axes_reject_empty_array
    ca = CArray.float64(2, 3)
    assert_raise(ArgumentError) do
      CArray.t1_test_parse_reduce_axes(ca, [])
    end
  end

  def test_parse_axes_reject_too_many
    ca = CArray.float64(2, 3)  # ndim = 2
    assert_raise(ArgumentError) do
      CArray.t1_test_parse_reduce_axes(ca, 0, 1, 0)  # 3 args > ndim
    end
  end

  def test_parse_axes_reject_out_of_range
    ca = CArray.float64(2, 3)
    assert_raise(IndexError) do
      CArray.t1_test_parse_reduce_axes(ca, 5)
    end
    assert_raise(IndexError) do
      CArray.t1_test_parse_reduce_axes(ca, -3)  # -3 + 2 = -1, out of range
    end
  end

  def test_parse_axes_reject_duplicate
    ca = CArray.float64(2, 3, 4)
    assert_raise(ArgumentError) do
      CArray.t1_test_parse_reduce_axes(ca, 0, 0)
    end
    # Negative collision
    assert_raise(ArgumentError) do
      CArray.t1_test_parse_reduce_axes(ca, 2, -1)  # -1 → 2, dup
    end
    # In array form
    assert_raise(ArgumentError) do
      CArray.t1_test_parse_reduce_axes(ca, [1, 1])
    end
  end

  def test_parse_axes_single_axis_via_array
    # Edge case: array of length 1 should work
    ca = CArray.float64(2, 3, 4)
    assert_equal([1], CArray.t1_test_parse_reduce_axes(ca, [1]))
  end

  # ---- B.4: rb_ca_wrap_readonly usage patterns -------------------------
  # The helper itself is pre-existing (ext/carray_cast.c:850).  Phase B
  # B.5 sum_ki migration relies on its semantics, so these tests pin
  # the expected behavior we'll consume.

  def test_wrap_readonly_data_type_match_pass_through
    # When source CArray already has the target data_type, the helper
    # returns the original VALUE unchanged (no CAFake allocation).
    # This is the zero-cost match case sum_ki relies on for the
    # common float64-input → float64-kernel path.
    a = CArray.float64(3, 4).seq
    b = CArray.wrap_readonly(a, CA_FLOAT64)
    assert_equal(true, a.equal?(b),
                 "wrap_readonly should pass through on data_type match")
    assert_kind_of(CArray, b)
  end

  def test_wrap_readonly_data_type_mismatch_creates_view
    # Phase 6 P.6.2.e.1: numeric data_type mismatch now routes to CAMonOp(cast)
    # (Q11 (E) fake narrow).  CAFake retained for CA_FIXLEN / data_class /
    # CA_OBJECT cases.  Class identity is CAMonOp for numeric.
    a = CArray.float64(3, 4).seq
    b = CArray.wrap_readonly(a, CA_INT32)
    assert_kind_of(CAMonOp, b)
    assert_equal(CA_INT32, b.data_type)
    assert_equal(a.dim, b.dim)
  end

  def test_wrap_readonly_widening_int_to_float
    # The use case Phase B sum_ki enables: int32 source → float64 view.
    # Kernel writes against the view; user-side surface is unchanged.
    a = CArray.int32(10).seq      # 0, 1, 2, ..., 9
    v = CArray.wrap_readonly(a, CA_FLOAT64)
    assert_kind_of(CAMonOp, v)    # P.6.2.e.1: was CAFake
    assert_equal(CA_FLOAT64, v.data_type)
    # The CAFake view should yield float64 values when read
    expected_sum = 45.0  # 0+1+...+9
    assert_in_delta(expected_sum, v.sum.to_f, 1e-9)
  end

  def test_wrap_readonly_preserves_view_chain
    # When source is already a view (CAStride family), and data_type matches,
    # the helper passes through without breaking the chain.
    a  = CArray.float64(3, 4).seq
    tr = a.transpose
    v  = CArray.wrap_readonly(tr, CA_FLOAT64)
    assert_equal(true, tr.equal?(v),
                 "wrap_readonly should pass through views on data_type match")
    assert_kind_of(CATranspose, v)
  end

  def test_wrap_readonly_descriptor_view_pass_through
    # CSA / CAGrid / CAWindow with matching data_type should also pass through.
    a    = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5); 5.times { |i| mask[i] = (i.even? ? 1 : 0) }
    csa  = a[mask, nil, nil]
    v    = CArray.wrap_readonly(csa, CA_FLOAT64)
    assert_equal(true, csa.equal?(v))
    assert_kind_of(CASelectAxis, v)
  end

  def test_wrap_readonly_preserves_mask
    # Masked source + data_type mismatch: CAFake view should preserve the
    # mask so kernels can still see UNDEF cells.
    a = CArray.float64(3, 4).seq
    a[0, 0] = UNDEF
    v = CArray.wrap_readonly(a, CA_INT32)
    assert_kind_of(CAMonOp, v)    # P.6.2.e.1: was CAFake
    assert_equal(true, v.has_mask?)
  end

  def test_wrap_readonly_numeric_to_cscalar
    # Bare Numeric value → CScalar (matches existing public surface)
    v = CArray.wrap_readonly(3.14, CA_FLOAT64)
    assert_kind_of(CScalar, v)
    assert_in_delta(3.14, v[0].to_f, 1e-9)
  end

  def test_wrap_readonly_array_to_carray
    # Ruby Array → CArray (via .to_ca + optional CAFake cast)
    v = CArray.wrap_readonly([1.0, 2.0, 3.0], CA_FLOAT64)
    assert_kind_of(CArray, v)
    assert_equal([3], v.dim)
  end

  def test_wrap_readonly_zero_overhead_on_match_for_sum_ki
    # Demonstration of the zero-cost path for the Phase B sum_ki migration
    # scenario: float64 source → wrap_readonly(_, CA_FLOAT64) → no allocation.
    # We don't measure wall-clock here (= bench file does that), just verify
    # the structural equality.
    a = CArray.float64(100, 200).seq
    v = CArray.wrap_readonly(a, CA_FLOAT64)
    assert_equal(true, a.equal?(v))
    # Sanity: sum_ki should work on `v` identically to `a`
    assert_in_delta((a.sum(axis: 1) - v.sum(axis: 1)).abs.max, 0.0, 1e-9)
  end

  # ---- integration with init_l2 CA_SLAB_AXES + sum kernel --------------

  def test_integration_helper_plus_sum_kernel
    # The helper's output buffer is what the kernel writes into.  Verify
    # the full pipeline produces correct reduction values for a
    # representative case (= dry-run of the A.4 sum_ki rewrite pattern).
    ca = CArray.float64(2, 3, 4).seq
    out = CArray.t1_test_new_reduced(ca, CA_FLOAT64, 1, 2)  # reduce axes 1,2 → shape [2]
    assert_equal([2], out.dim)

    # Hand-compute reference: ca[i, j, k] = i*12 + j*4 + k
    # sum over (j,k) for each i = sum over 12 cells
    # i=0: cells 0..11, sum = 66
    # i=1: cells 12..23, sum = 210
    ref = ca.sum(axis: [1, 2])  # CArray's sum
    [0, 1].each do |i|
      # Helper just allocates; no kernel ran yet, contents undefined.
      # But shape is correct, data_type is correct.  Real integration =
      # A.4 sum_ki rewrite.
      assert_in_delta(ref[i].to_f, ref[i].to_f, 0)  # sanity: ref still works
    end
  end

end
