# frozen_string_literal: true
#
# W.2: wsum mkkernel migration parity + new semantic pin.
#
# Validates the wsum kernel (= mkkernel array_arg framework, public_method)
# against:
#   - basic correctness (= match against hand-computed expected values)
#   - mask overlay (weights.mask OR self.mask)
#   - 3.0 breaking semantics documented in PROPOSAL_WEIGHTED_REDUCTION rev3:
#     * calling convention: (w, *axes, min_count:, fill_value:)
#     * min_count = "min valid required" (= Phase E sum precedent)
#     * complex / CA_OBJECT rejection (= 3.0 breaking from legacy)
#   - per-axis support (= "per-axis 解禁" original goal)
#
# Note: the original W.1 framework smoke (wsum_smoke_ki +
# test_w1_array_arg_framework.rb) was retired once W.2 production wsum
# landed -- this file is now the sole regression pin for the
# array_arg DSL framework contract.

require "test/unit"
require "carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestW2Wsum < Test::Unit::TestCase

  # ---- basic correctness (legacy parity for non-complex/non-object) ---

  def test_int_source_int_weights
    a = CArray.int32(10).seq!(1)  # [1..10]
    w = CArray.int32(10).seq!(1)  # [1..10]
    # 1*1 + 2*2 + ... + 10*10 = 385
    assert_in_delta(385.0, a.wsum(w), 1e-12)
  end

  def test_float64_source
    a = CArray.float64(10).seq!(1)
    w = CArray.float64(10).seq!(1)
    assert_in_delta(385.0, a.wsum(w), 1e-12)
  end

  def test_returns_float_for_full_reduction
    a = CArray.int32(5) { |i| (i + 1) }
    w = CArray.int32(5) { 1 }
    r = a.wsum(w)
    assert_kind_of(Float, r)
  end

  # ---- per-axis (W.2 newly supported) ----------------------------------

  def test_per_axis_2d_axis0
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    # a = [[1,2,3], [4,5,6]]
    w = CArray.float64(2, 3) { 1.0 }
    # axis 0 reduce: per-column = [1+4, 2+5, 3+6] = [5, 7, 9]
    assert_equal([5.0, 7.0, 9.0], a.wsum(w, axis: 0).to_a)
  end

  def test_per_axis_2d_axis1
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    w = CArray.float64(2, 3) { 1.0 }
    # axis 1 reduce: per-row = [1+2+3, 4+5+6] = [6, 15]
    assert_equal([6.0, 15.0], a.wsum(w, axis: 1).to_a)
  end

  def test_per_axis_multi_axis_3d
    a = CArray.float64(2, 2, 2) { |i, j, k| 1.0 + i * 4 + j * 2 + k }
    w = CArray.float64(2, 2, 2) { 1.0 }
    # reduce axes 1, 2: per-plane sum
    # plane 0: 1+2+3+4 = 10; plane 1: 5+6+7+8 = 26
    assert_equal([10.0, 26.0], a.wsum(w, axis: [1, 2]).to_a)
  end

  # ---- mask semantics (Q3 A: overlay self.mask | weights.mask) --------

  def test_self_mask_skips
    a = CArray.float64(4) { |i| (i + 1).to_f }  # [1,2,3,4]
    a[1] = UNDEF
    w = CArray.float64(4) { 1.0 }
    # skip cell 1 -> 1 + 3 + 4 = 8
    assert_in_delta(8.0, a.wsum(w), 1e-12)
  end

  def test_weights_mask_overlay
    a = CArray.float64(4) { |i| (i + 1).to_f }
    w = CArray.float64(4) { 1.0 }
    w[2] = UNDEF
    # weights mask -> self.mask via overlay; skip cell 2 -> 1+2+4 = 7
    assert_in_delta(7.0, a.wsum(w), 1e-12)
    # original a unchanged
    assert_false(a.has_mask?)
  end

  def test_combined_mask
    a = CArray.int32(10).seq!(1) # [1..10]
    w = CArray.int32(10).seq!(1)
    a.mask = 0
    w.mask = 0
    a[0] = UNDEF
    w[9] = UNDEF
    # effective mask = {0, 9}; valid: a[1..8] * w[1..8] = 4+9+...+81 = 284
    assert_in_delta(284.0, a.wsum(w), 1e-12)
  end

  def test_all_masked_returns_identity
    # ERI.2: weighted sum over an all-masked array = weighted sum over the
    # empty set of unmasked cells = 0.0 (identity), NOT UNDEF, under the
    # default min_count.  UNDEF is opt-in via min_count: 1.
    a = CArray.float64(3) { 1.0 }
    a[0] = a[1] = a[2] = UNDEF
    w = CArray.float64(3) { 1.0 }
    assert_equal(0.0, a.wsum(w))
    assert_equal(UNDEF, a.wsum(w, min_count: 1))
  end

  # ---- min_count semantic (3.0 breaking from legacy "max masked") -----

  def test_min_count_requires_min_valid
    # 10 elements, 2 masked -> valid_count = 8
    a = CArray.int32(10).seq!(1)
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF
    w = CArray.int32(10) { 1 }
    # valid_count = 8 >= 8 -> compute (= 2+3+...+9 = 44)
    assert_in_delta(44.0, a.wsum(w, min_count: 8), 1e-12)
    # valid_count = 8 < 9 -> UNDEF
    assert_equal(UNDEF, a.wsum(w, min_count: 9))
    # valid_count = 8 < 10 -> UNDEF
    assert_equal(UNDEF, a.wsum(w, min_count: 10))
  end

  def test_fill_value_substitutes_undef
    # ERI.2: all-masked is now identity 0.0 (not UNDEF) under default
    # min_count, so fill_value has nothing to fill.  min_count: 1 forces a
    # genuine UNDEF that fill_value replaces.
    a = CArray.float64(3) { 1.0 }
    a[0] = a[1] = a[2] = UNDEF
    w = CArray.float64(3) { 1.0 }
    assert_equal(-9999.0, a.wsum(w, min_count: 1, fill_value: -9999.0))
  end

  # ---- 3.0 breaking: complex rejection --------------------------------

  def test_complex_source_raises
    cmplx_a = CArray.cmplx128(3) { Complex(1.0, 0.0) }
    cmplx_w = CArray.cmplx128(3) { Complex(1.0, 0.0) }
    # ALL_NUMERIC excludes CMPLX, fallback :raise -> DataTypeError
    assert_raise(CArray::DataTypeError) { cmplx_a.wsum(cmplx_w) }
  end if CArray::HAVE_COMPLEX

  # CA_OBJECT is now handled via the object_escape hook (runtime.rb
  # __wsum_object__ = (self*w).sum), not rejected.  See test_object_wsum_wmean.
  def test_object_source_works
    obj_a = CArray.object(3) { |i| (i + 1).to_f }
    obj_w = CArray.object(3) { 1.0 }
    assert_in_delta(6.0, obj_a.wsum(obj_w), 1e-12)
  end

  # ---- shape / data_type validation ---------------------------------------

  def test_shape_mismatch_raises
    # rev5 strict: shape validation raises ArgumentError (= Ruby idiom)、
    # legacy RuntimeError から flip。
    a = CArray.float64(3) { |i| i.to_f }
    w = CArray.float64(4) { |i| i.to_f }
    assert_raise(ArgumentError) { a.wsum(w) }
  end

  def test_shape_mismatch_2d_vs_1d_raises
    # rev5: self [2, 3] (= flatten reduce, naxes=2)、w 1-D length 6 は
    # W-A2 (axes.length==1 限定) に該当せず、cv->ndim(1) != src->ndim(2) で
    # W-A3 にも該当せず → ArgumentError。
    a = CArray.float64(2, 3) { |i, j| 1.0 }
    w = CArray.float64(6) { |i| 1.0 }
    assert_raise(ArgumentError) { a.wsum(w) }
  end

  def test_missing_weights_raises
    a = CArray.float64(3) { |i| i.to_f }
    assert_raise(ArgumentError) { a.wsum }
  end

  def test_float_weights_not_truncated_against_int_source
    # int32 self + f64 weights: weights materialize at the f64 computation
    # type (data_type: :promote), so a fractional weight is NOT truncated to
    # the source type.  10*1.5 + 20*2.5 + 30*3.5 = 15 + 50 + 105 = 170.
    a = CArray.int32(3) { |i| [10, 20, 30][i] }
    w = CArray.float64(3) { |i| [1.5, 2.5, 3.5][i] }
    assert_in_delta(170.0, a.wsum(w), 1e-12)
  end

  # ---- view source (non-contig) ---------------------------------------

  def test_view_source_via_transpose
    base = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    a = base.transpose                       # shape [3, 2]
    w = CArray.float64(3, 2) { 1.0 }
    # transposed * ones = plain sum of all cells = 1+2+3+4+5+6 = 21
    assert_in_delta(21.0, a.wsum(w), 1e-12)
  end
end
