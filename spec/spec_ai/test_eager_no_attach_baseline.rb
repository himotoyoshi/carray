# PROPOSAL_EAGER_ELEMENTWISE_NO_ATTACH — baseline pin tests (E.1)
#
# Core invariant: "eager element-wise driver does not attach input-only
# operand".  This test file uses CAMockUnattachable (= CAStride pass-through
# whose attach/allocate slots raise) as input-only operand to all 8 drivers
# and asserts the operation completes without raising.
#
# Baseline (current state): drivers call ca_attach_n on operands → mock
# raises → tests are omit'd.  After E.2-E.5 landing, each driver's tests
# flip from `omit` to live assertion.  Phase Landed = all omits flipped.
#
# 8 drivers (= ext/carray_operator.c):
#   non-bang: monop / binop / triop / moncmp / bincmp  ← 5
#   bang:     monop_bang / binop_bang / triop_bang     ← 3
#
# Build the mock ext:
#   cd spec_ai/ext_eager_no_attach_test && ruby extconf.rb && make
# Or via Rakefile task: rake build_mock_unattachable

require "test/unit"
require "carray"

mock_dir = File.expand_path("ext_eager_no_attach_test", __dir__)
$LOAD_PATH.unshift(mock_dir)
begin
  require "mock_unattachable"
rescue LoadError
  warn "Skipping test_eager_no_attach_baseline: mock_unattachable not built."
  warn "Build it with: (cd #{mock_dir} && ruby extconf.rb && make)"
  return
end

class TestEagerNoAttachBaseline < Test::Unit::TestCase

  # Pending-marker reason.  When E.x lands and the corresponding driver
  # path is migrated, remove the `omit` line in the matching tests.
  PENDING_E2  = "PENDING E.2 landing (rb_ca_call_binop migration)"
  PENDING_E2B = "PENDING E.2b landing (rb_ca_call_binop_bang migration)"
  PENDING_E3  = "PENDING E.3 landing (rb_ca_call_monop migration)"
  PENDING_E3B = "PENDING E.3b landing (rb_ca_call_monop_bang migration)"
  PENDING_E4  = "PENDING E.4 landing (rb_ca_call_triop migration)"
  PENDING_E4B = "PENDING E.4b landing (rb_ca_call_triop_bang migration)"
  PENDING_E5  = "PENDING E.5 landing (rb_ca_call_moncmp/bincmp migration)"

  # ----- helpers ------------------------------------------------------

  def entity(seed: 0)
    CArray.float64(5).seq(seed.to_f, 1.0)
  end

  def mock_of(seed: 10)
    CAMockUnattachable.wrap(entity(seed: seed))
  end

  # C.3 (PROPOSAL_EAGER_SLOWPATH_CHUNKING_ARENA): mock whose parent
  # carries a mask.  Exercises ca_mask_overlay_safe path (= operand
  # mask gathered via ca_xfer_all, not ca_attach).  `masked_indices`
  # specifies which cells in the underlying parent are UNDEF.
  def mock_with_mask(seed: 10, masked_indices: [1, 3])
    parent = entity(seed: seed)
    masked_indices.each { |i| parent[i] = UNDEF }
    CAMockUnattachable.wrap(parent)
  end

  # Baseline sanity: mock.attach itself must raise.  This is the
  # foundation — if mock doesn't raise on attach, all other tests are
  # meaningless.  This test does NOT depend on E.x landing and must
  # always pass.
  def test_baseline_mock_attach_raises
    m = mock_of
    assert_raise(RuntimeError) { m.attach }
  end

  # ----- binop (E.2) --------------------------------------------------

  def test_binop_other_is_mock
    a = entity(seed: 0)
    m = mock_of(seed: 10)
    result = a + m
    assert_equal [10.0, 12.0, 14.0, 16.0, 18.0], result.to_a
  end

  def test_binop_self_is_mock
    m = mock_of(seed: 10)
    b = entity(seed: 0)
    result = m + b
    assert_equal [10.0, 12.0, 14.0, 16.0, 18.0], result.to_a
  end

  def test_binop_both_mock
    m1 = mock_of(seed: 0)
    m2 = mock_of(seed: 10)
    result = m1 + m2
    assert_equal [10.0, 12.0, 14.0, 16.0, 18.0], result.to_a
  end

  # C.3 acceptance (= proposal §3.4): mock whose parent carries a mask.
  # Pre-C.3 this would raise because ca_copy_mask_overlay calls
  # ca_attach on the mock's mask (= CAMockUnattachableMask, attach
  # inherited from mock's raising slot).  Post-C.3, ca_mask_overlay_safe
  # gathers via ca_xfer_all (no attach) → succeeds and mask propagates.
  def test_binop_other_is_mock_with_mask
    a = entity(seed: 0)
    m = mock_with_mask(seed: 10, masked_indices: [1, 3])
    result = a + m
    # Eager driver semantic: masked-cell output data = 0 (from
    # ca_template_safe init); unmasked cells compute normally.
    assert_equal [10.0, 0.0, 14.0, 0.0, 18.0], result.value.to_a
    assert_equal [false, true, false, true, false], result.is_masked.to_a
  end

  def test_binop_self_is_mock_with_mask
    m = mock_with_mask(seed: 10, masked_indices: [0, 4])
    b = entity(seed: 0)
    result = m + b
    assert_equal [0.0, 12.0, 14.0, 16.0, 0.0], result.value.to_a
    assert_equal [true, false, false, false, true], result.is_masked.to_a
  end

  def test_binop_both_mock_with_mask_or_fold
    # Mask OR-fold: m1 masked at [1], m2 masked at [3] → result masked at [1, 3]
    m1 = mock_with_mask(seed: 0,  masked_indices: [1])
    m2 = mock_with_mask(seed: 10, masked_indices: [3])
    result = m1 + m2
    assert_equal [10.0, 0.0, 14.0, 0.0, 18.0], result.value.to_a
    assert_equal [false, true, false, true, false], result.is_masked.to_a
  end

  # ----- binop_bang (E.2b) -------------------------------------------
  # self must be an entity (output = write target, attach legitimate).
  # Only `other = mock` is the input-only-operand case.

  def test_binop_bang_other_is_mock
    a = entity(seed: 0)
    m = mock_of(seed: 10)
    a.add!(m)
    assert_equal [10.0, 12.0, 14.0, 16.0, 18.0], a.to_a
  end

  # ----- monop (E.3) --------------------------------------------------

  def test_monop_self_is_mock
    m = mock_of(seed: 1)  # 1..5, sqrt safe
    result = m.sqrt
    assert_equal [Math.sqrt(1.0), Math.sqrt(2.0), Math.sqrt(3.0),
                  Math.sqrt(4.0), Math.sqrt(5.0)], result.to_a
  end

  # C.4 acceptance: monop self = mock with masked parent.
  def test_monop_self_is_mock_with_mask
    m = mock_with_mask(seed: 1, masked_indices: [0, 4])
    result = m.sqrt
    # unmasked: sqrt(2), sqrt(3), sqrt(4) at idx 1, 2, 3
    assert_equal Math.sqrt(2.0), result.value.to_a[1]
    assert_equal Math.sqrt(3.0), result.value.to_a[2]
    assert_equal Math.sqrt(4.0), result.value.to_a[3]
    assert_equal [true, false, false, false, true], result.is_masked.to_a
  end

  # ----- monop_bang (E.3b) -------------------------------------------
  # NOTE: monop_bang's self is both input and output.  Per refined
  # invariant, output (= self for bang) attach is permitted.  So
  # `mock.sqrt!` is NOT a valid "input-only operand" case — it would
  # legitimately need to attach mock as output.  There is no monop_bang
  # case where mock appears as input-only operand.  This sub-step
  # (E.3b) has no test here; its acceptance is via regression sweep
  # (= existing monop_bang tests must still pass after migration).
  #
  # Documenting this absence as a positive assertion of the design.
  def test_monop_bang_has_no_input_only_case
    # No-op assertion documenting that monop_bang's only operand (= self)
    # is also output, so input-only-attach test is not applicable.
    assert true
  end

  # ----- triop (E.4) --------------------------------------------------

  def test_triop_other2_is_mock
    a  = entity(seed: 0)
    lo = mock_of(seed: 1)  # 1..5
    hi = entity(seed: 6)    # 6..10
    result = a.clip(lo, hi)
    # a = [0,1,2,3,4], lo = [1,2,3,4,5], hi = [6,7,8,9,10]
    # result[k] = max(a[k], lo[k]) clipped to hi[k] = [1,2,3,4,5]
    assert_equal [1.0, 2.0, 3.0, 4.0, 5.0], result.to_a
  end

  def test_triop_other3_is_mock
    a  = entity(seed: 0)
    lo = entity(seed: 1)
    hi = mock_of(seed: 6)
    result = a.clip(lo, hi)
    assert_equal [1.0, 2.0, 3.0, 4.0, 5.0], result.to_a
  end

  def test_triop_fma_input_is_mock
    a = entity(seed: 1)         # 1..5
    b = mock_of(seed: 2)        # 2..6
    c = entity(seed: 10)        # 10..14
    # fma(a, b, c) = a * b + c (= [12, 16, 22, 30, 40] -- a*b+c)
    result = a.fma(b, c)
    expected = (0..4).map { |k| (1.0 + k) * (2.0 + k) + (10.0 + k) }
    assert_equal expected, result.to_a
  end

  # C.5a acceptance: triop chunked branch (= 2+ non-alias array operands).
  def test_triop_chunked_all_mock
    m1 = mock_of(seed: 1)  # 1..5
    m2 = mock_of(seed: 2)  # 2..6
    m3 = mock_of(seed: 10) # 10..14
    result = m1.fma(m2, m3)
    expected = (0..4).map { |k| (1.0 + k) * (2.0 + k) + (10.0 + k) }
    assert_equal expected, result.to_a
  end

  # C.5a acceptance: triop with mock-with-mask in chunked branch.
  def test_triop_chunked_mock_with_mask
    m1 = mock_with_mask(seed: 1, masked_indices: [0])
    m2 = mock_with_mask(seed: 2, masked_indices: [4])
    m3 = mock_of(seed: 10)
    result = m1.fma(m2, m3)
    # mask OR-fold: m1[0] | m2[4] = [1, 0, 0, 0, 1]
    assert_equal [true, false, false, false, true], result.is_masked.to_a
  end

  # ----- triop_bang (E.4b) -------------------------------------------

  def test_triop_bang_other2_is_mock
    # Use fma! (a.fma!(b, c) = a*b+c in-place); clip! is undef'd in 3.0
    # per view-by-default convention (= `a[] = a.clip(lo, hi)` idiom).
    a = entity(seed: 1)     # 1..5
    b = mock_of(seed: 2)    # 2..6
    c = entity(seed: 10)    # 10..14
    a.fma!(b, c)
    expected = (0..4).map { |k| (1.0 + k) * (2.0 + k) + (10.0 + k) }
    assert_equal expected, a.to_a
  end

  # C.5b acceptance: triop_bang chunked branch (= both other2 / other3
  # non-alias arrays).  Self IS output (attach + sync legitimate).
  def test_triop_bang_chunked_both_mock
    a = entity(seed: 1)         # 1..5 (self = output, must be entity)
    m_b = mock_of(seed: 2)      # 2..6
    m_c = mock_of(seed: 10)     # 10..14
    a.fma!(m_b, m_c)
    expected = (0..4).map { |k| (1.0 + k) * (2.0 + k) + (10.0 + k) }
    assert_equal expected, a.to_a
  end

  # ----- ipower (C.7) -------------------------------------------------
  # `a ** Integer` on Float/Complex uses rb_ca_ipower hand-rolled fast
  # path (binary exponentiation O(log p)) bypassing the standard monop
  # driver.  Pre-C.7 this path called ca_attach(operand) directly;
  # post-C.7 it uses alias/non-alias bifurcation + ca_mask_overlay_safe
  # (= same pattern as rb_ca_call_monop).

  def test_ipower_self_is_mock
    m = mock_of(seed: 1)  # 1..5
    result = m ** 2
    assert_equal [1.0, 4.0, 9.0, 16.0, 25.0], result.to_a
  end

  def test_ipower_self_is_mock_with_mask
    m = mock_with_mask(seed: 1, masked_indices: [1, 3])
    result = m ** 2
    # masked cell output = 0 (template_safe init); unmasked = x*x
    assert_equal [1.0, 0.0, 9.0, 0.0, 25.0], result.value.to_a
    assert_equal [false, true, false, true, false], result.is_masked.to_a
  end

  # ----- ca_call_cfunc API (D phase) ----------------------------------
  # The ca_call_cfunc_N / ca_call_cfunc_M_N family is the ext-author math
  # wrapper API used by external CArray gems (carray-gsl etc.).  Internal
  # consumer: ext/carray_mathfunc.c (deg_360, deg_180, rad_2pi, rad_pi,
  # atan2, hypot, lgamma, expm1, spherical_to_xyz, xyz_to_spherical).
  # Pre-D this called ca_attach on operand directly; post-D the generated
  # template applies the same alias / non-alias bifurcation + safe mask
  # gather as the parent phase drivers.

  def test_ca_call_cfunc_1_1_self_is_mock
    # deg_360 is a 1-input mathfunc backed by ca_call_cfunc_1_1.  Mock
    # operand must not raise.
    parent = CArray.double(5)
    parent[] = [-450.0, -90.0, 0.0, 90.0, 450.0]
    m = CAMockUnattachable.wrap(parent)
    assert_equal [270.0, 270.0, 0.0, 90.0, 90.0], m.deg_360.to_a
  end

  def test_ca_call_cfunc_1_2_other_is_mock
    # atan2(y, x) is backed by ca_call_cfunc_1_2.
    y_parent = CArray.double(3); y_parent[] = [1.0, -1.0, 0.0]
    x_parent = CArray.double(3); x_parent[] = [1.0, 1.0, -1.0]
    y_mock = CAMockUnattachable.wrap(y_parent)
    x_mock = CAMockUnattachable.wrap(x_parent)
    # Both inputs are mocks (attach-hostile); the wrapper must materialize
    # via ca_xfer_all, not ca_attach.
    result = CAMath.atan2(y_mock, x_mock).to_a
    expected = [Math::PI / 4, -Math::PI / 4, Math::PI]
    expected.each_with_index do |e, i|
      assert_in_delta e, result[i], 1e-12
    end
  end

  def test_ca_call_cfunc_1_1_self_is_mock_with_mask
    # Mask must propagate via the safe gather path (not ca_attach on
    # operand mask), and the output mask must be set correctly.
    parent = CArray.double(5)
    parent[] = [10.0, 20.0, 30.0, 40.0, 50.0]
    parent[2] = UNDEF
    m = CAMockUnattachable.wrap(parent)
    result = m.deg_360
    # mask propagates to index 2
    assert_equal [false, false, true, false, false], result.is_masked.to_a
    # unmasked values still computed correctly
    assert_equal 10.0, result.value.to_a[0]
    assert_equal 20.0, result.value.to_a[1]
    assert_equal 40.0, result.value.to_a[3]
  end

  # ----- moncmp (E.5) -------------------------------------------------

  def test_moncmp_self_is_mock
    m = mock_of(seed: 0)
    result = m.is_finite
    # CArray boolean's to_a returns Integer 1/0 (not true/false)
    assert_equal [true, true, true, true, true], result.to_a
  end

  # C.4 acceptance: moncmp self = mock with masked parent.
  def test_moncmp_self_is_mock_with_mask
    m = mock_with_mask(seed: 0, masked_indices: [2])
    result = m.is_finite
    # mask propagates to output, value at masked position is don't-care
    assert_equal [false, false, true, false, false], result.is_masked.to_a
  end

  # ----- bincmp (E.5) -------------------------------------------------

  def test_bincmp_other_is_mock
    a = entity(seed: 0)
    m = mock_of(seed: 2)
    result = a < m
    assert_equal [true, true, true, true, true], result.to_a
  end

  def test_bincmp_self_is_mock
    m = mock_of(seed: 0)
    b = entity(seed: 2)
    result = m < b
    assert_equal [true, true, true, true, true], result.to_a
  end

  # C.4 acceptance: bincmp with mock-with-mask operand.  Exercises both
  # the new chunked branch (= 2 non-alias) and the 1-shot fallback
  # (= 1 non-alias) of ca_mask_overlay_safe.
  def test_bincmp_mock_with_mask_distinct
    m = mock_with_mask(seed: 2, masked_indices: [1, 3])  # non-alias
    b = entity(seed: 0)                                   # alias entity
    result = b < m
    # 1-shot branch (= 1 non-alias array): a + mock-with-mask passes
    # safely; mask propagates from operand mask without ca_attach.
    assert_equal [false, true, false, true, false], result.is_masked.to_a
  end

  def test_bincmp_both_mock_with_mask
    m1 = mock_with_mask(seed: 0, masked_indices: [1])
    m2 = mock_with_mask(seed: 2, masked_indices: [3])
    result = m1 < m2
    # chunked branch (= 2 non-alias arrays).  Mask OR-fold.
    assert_equal [false, true, false, true, false], result.is_masked.to_a
  end

end
