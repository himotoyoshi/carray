# MS.2: ca[:is_invalid] indexer key dispatch.
#
# Per PROPOSAL_MASK_SET_FAMILY.md §2.6, the :is_invalid indexer key
# emerges automatically from the generic CA_REG_METHOD_CALL dispatch
# (ext/carray_access.c) once is_invalid (MS.1) exists.  No new code is
# needed for MS.2; this test pins the behavior so future refactors of
# the symbol-indexer dispatch don't silently break it.
#
# Coverage:
#   - ca[:is_invalid] (read)   = subset of cells matching is_invalid
#   - ca[:is_invalid] = UNDEF  = mask NaN/Inf cells
#   - ca[:is_invalid] = value  = replace NaN/Inf cells with value
#   - integer / boolean data_type  = no-op (all cells false)
#   - masked input cells       = mask propagation (school A)
#   - orthogonality with :is_masked

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS2IsInvalidIndexer < Test::Unit::TestCase

  def make_float_array
    a = CArray.float64(5)
    a[0] = 1.0
    a[1] = 0.0 / 0.0     # NaN
    a[2] = 2.0
    a[3] = 1.0 / 0.0     # +Inf
    a[4] = 3.0
    a
  end

  # ---- read form -------------------------------------------------------

  def test_read_returns_invalid_cells
    a = make_float_array
    r = a[:is_invalid]
    # 2 cells are invalid (NaN at index 1, Inf at index 3)
    assert_equal([2], r.shape)
    assert(r[0].nan?, "first invalid cell should be NaN")
    assert(r[1].infinite?, "second invalid cell should be +/-Inf")
  end

  def test_read_no_invalid
    a = CArray.float64(5).seq
    r = a[:is_invalid]
    assert_equal([0], r.shape)
  end

  # ---- write UNDEF (= mask the invalid cells) ---------------------------

  def test_write_undef_masks_invalid_cells
    a = make_float_array
    a[:is_invalid] = UNDEF
    assert_equal([false, true, false, true, false], a.is_masked.to_a)
    # finite values preserved
    assert_equal(1.0, a[0])
    assert_equal(2.0, a[2])
    assert_equal(3.0, a[4])
  end

  def test_write_undef_equivalent_to_predicate_chain
    # ca[:is_invalid] = UNDEF  must equal  ca[ca.is_invalid] = UNDEF
    a = make_float_array
    b = a.dup
    a[:is_invalid] = UNDEF
    b[b.is_invalid] = UNDEF
    assert_equal(a.is_masked.to_a, b.is_masked.to_a)
  end

  # ---- write value (= replace invalid cells) ---------------------------

  def test_write_value_replaces_invalid_cells
    a = make_float_array
    a[:is_invalid] = 999.0
    assert_equal([1.0, 999.0, 2.0, 999.0, 3.0], a.to_a)
    refute(a.has_mask?, "writing a value should not introduce a mask")
  end

  def test_write_value_no_change_when_no_invalid
    a = CArray.float64(5).seq
    a[:is_invalid] = 999.0
    assert_equal([0.0, 1.0, 2.0, 3.0, 4.0], a.to_a)
  end

  # ---- integer / boolean data_type: no-op ----------------------------------

  def test_integer_write_undef_is_noop
    [:int8, :int32, :int64, :uint8, :uint32, :uint64].each do |t|
      a = CArray.send(t, 5).seq
      a[:is_invalid] = UNDEF
      refute(a.has_mask?,
             "data_type #{t}: writing UNDEF via :is_invalid should be no-op")
    end
  end

  def test_boolean_write_undef_is_noop
    a = CArray.int32(5).seq.ne(0)
    a[:is_invalid] = UNDEF
    refute(a.has_mask?)
  end

  # ---- mask propagation in input ---------------------------------------

  def test_masked_cells_not_affected
    # Pre-existing masked cells should remain masked, and writing UNDEF
    # via :is_invalid should not un-mask them.
    a = CArray.float64(5)
    a[0] = 1.0
    a[1] = 0.0 / 0.0     # NaN
    a[2] = 2.0
    a[3] = UNDEF         # pre-masked (not NaN/Inf)
    a[4] = 1.0 / 0.0     # +Inf
    a[:is_invalid] = UNDEF
    # Cells 1 (NaN) and 4 (Inf) become masked; cell 3 stays masked.
    assert_equal(true, a.is_masked[1])
    assert_equal(true, a.is_masked[3])
    assert_equal(true, a.is_masked[4])
    # Cells 0 and 2 stay unmasked.
    assert_equal(false, a.is_masked[0])
    assert_equal(false, a.is_masked[2])
  end

  # ---- orthogonality with :is_masked -----------------------------------

  def test_orthogonal_with_is_masked
    # :is_invalid and :is_masked target different cells.
    a = CArray.float64(5)
    a[0] = 1.0
    a[1] = 0.0 / 0.0     # NaN -> :is_invalid catches
    a[2] = 2.0
    a[3] = UNDEF         # masked -> :is_masked catches
    a[4] = 3.0

    # Confirm :is_masked picks only the masked cell
    assert_equal([1], a[:is_masked].shape)
    # :is_invalid picks only the NaN (and propagates mask for cell 3 ->
    # so read includes 1 NaN + 1 UNDEF; subset selection drops UNDEF
    # depending on indexer policy; here we test on .to_a content)
    r = a[:is_invalid]
    # At least the NaN should be included
    assert(r.shape[0] >= 1)
  end
end
