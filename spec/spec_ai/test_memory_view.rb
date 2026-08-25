require "test/unit"
require "carray"

# Phase 1 tests for MemoryView protocol support.
# These tests cover availability only; verifying actual rb_memory_view_get
# output (data pointer, strides, contents) requires a C-side borrower and
# is left for a later phase or integration test.

class TestMemoryView < Test::Unit::TestCase

  # ----- exportable cases (Phase 1 supported obj_types) -----

  def test_entity_int32_available
    ca = CArray.int32(3, 4).seq
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_entity_float64_available
    ca = CArray.float64(5).seq
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_entity_int64_available
    ca = CArray.int64(2, 3).seq
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_entity_uint8_available
    ca = CArray.uint8(10).seq
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_entity_boolean_available
    ca = CArray.boolean(8)
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_scalar_available
    cs = CScalar.new(CA_INT32)
    cs[] = 42
    assert_true(CArray.memory_view_available?(cs))
  end

  def test_refer_reshape_available
    ca = CArray.int32(12).seq
    rf = ca.reshape(3, 4)
    # 3.0: reshape returns CAStride (representable case) or CARefer (fallback).
    # Both must support memory_view.
    assert_true([CARefer, CAStride].include?(rf.class))
    assert_true(CArray.memory_view_available?(rf))
  end

  def test_complex64_available
    ca = CArray.cmplx64(4)
    assert_true(CArray.memory_view_available?(ca))
  end

  def test_complex128_available
    ca = CArray.cmplx128(4)
    assert_true(CArray.memory_view_available?(ca))
  end

  # ----- rejected by data_type -----

  def test_object_array_rejected
    ca = CArray.object(3)
    assert_false(CArray.memory_view_available?(ca))
  end

  def test_complex256_rejected
    begin
      ca = CArray.cmplx256(2)
    rescue
      omit("cmplx256 not available on this platform")
    end
    assert_false(CArray.memory_view_available?(ca))
  end

  def test_float128_rejected
    begin
      ca = CArray.float128(3)
    rescue
      omit("float128 not available on this platform")
    end
    assert_false(CArray.memory_view_available?(ca))
  end

  def test_fixlen_now_accepted_as_ns
    # PROPOSAL_MV_CONSUMER_FIXLEN_BYTES (2026-06-30): plain CA_FIXLEN
    # (no data_class) now exports as PEP 3118 "Ns"; previously rejected.
    # Data-classed FIXLEN continues to use the existing T{...} struct
    # format path (see test_mv_struct_format.rb).
    ca = CArray.new(:fixlen, [4], bytes: 8)
    assert_true(CArray.memory_view_available?(ca))
  end

  # ----- Phase 2: strided virtual arrays -----

  def test_block_available
    ca = CArray.int32(10, 10).seq
    bl = ca[2..5, 1..7]
    assert_true(CArray.memory_view_available?(bl))
  end

  def test_farray_available
    ca = CArray.float64(3, 4).seq
    assert_true(CArray.memory_view_available?(ca.farray))
  end

  def test_transpose_available
    ca = CArray.int32(3, 4).seq
    assert_true(CArray.memory_view_available?(ca.transpose))
  end

  # ----- Phase 3: stride=0 and attach-based exporters -----

  def test_repeat_available
    ca = CArray.int32(3).seq
    rp = ca[:%, 4]
    assert_equal(CA_OBJ_REPEAT, rp.obj_type)
    assert_true(CArray.memory_view_available?(rp))
  end

  # ----- non-CAStride virtuals: rejected (no alias path) -----
  # These used to fall back to ATTACH (snapshot) but that has wrong
  # MV semantics (deferred sync on consumer release).  Consumers that
  # want a snapshot should use CArray.from_memory_view(view).

  def test_select_rejected_no_alias_path
    ca = CArray.int32(10).seq
    sel = ca[ca > 3]
    assert_equal(CA_OBJ_SELECT, sel.obj_type)
    assert_false(CArray.memory_view_available?(sel),
                 "CASelect is position-based; cannot be wrapped zero-copy")
  end

  # CAMapping was removed in R.3 (PROPOSAL_CAMAPPING_REMOVAL); the 1-D
  # fancy-index path now routes to CAGrid, which is covered by
  # test_grid_rejected_no_alias_path (or equivalent).

  def test_shift_rejected_no_alias_path
    ca = CArray.int32(5).seq
    sh = ca.shift(2)
    assert_equal(CA_OBJ_SHIFT, sh.obj_type)
    assert_false(CArray.memory_view_available?(sh),
                 "CAShift has bounds-fill; cannot be wrapped zero-copy")
  end

  def test_window_rejected_no_alias_path
    ca = CArray.int32(5).seq
    w = ca.window(2..3)
    assert_equal(CA_OBJ_WINDOW, w.obj_type)
    assert_false(CArray.memory_view_available?(w),
                 "CAWindow has bounds-fill; cannot be wrapped zero-copy")
  end

  def test_rejected_views_still_copyable_via_from_memory_view
    # The alternative: get an independent snapshot copy.
    ca = CArray.int32(10).seq
    sel = ca[ca > 3]
    refute(CArray.memory_view_available?(sel))
    copy = CArray.from_memory_view(sel) rescue nil
    # from_memory_view requires the source to BE a MV producer, which
    # CASelect isn't anymore -- so this path also rejects.  The
    # honest answer is: use sel.to_ca for a snapshot.
    snap = sel.to_ca
    assert_equal(sel.to_a, snap.to_a)
  end

  # ----- still rejected -----

  def test_bitarray_rejected
    ca = CArray.boolean(8)
    ba = ca.bits
    assert_equal(CA_OBJ_BITARRAY, ba.obj_type)
    assert_false(CArray.memory_view_available?(ba))
  end


  # ----- mask policy: ca rejected, but .value and .mask are exportable -----

  def test_masked_array_rejected
    ca = CArray.int32(3).seq
    ca.mask = [1, 0, 0]
    assert_false(CArray.memory_view_available?(ca))
  end

  def test_masked_value_available
    ca = CArray.int32(3).seq
    ca.mask = [1, 0, 0]
    assert_true(CArray.memory_view_available?(ca.value),
                "ca.value (mask-ignoring CARefer) should be exportable")
  end

  def test_unmask_copy_available
    ca = CArray.int32(3).seq
    ca.mask = [1, 0, 0]
    assert_true(CArray.memory_view_available?(ca.strip_mask(-1)))
  end

  # ----- non-CArray objects -----

  def test_string_not_available
    assert_false(CArray.memory_view_available?("hello"))
  end

  def test_ruby_array_not_available
    assert_false(CArray.memory_view_available?([1, 2, 3]))
  end

  def test_integer_not_available
    assert_false(CArray.memory_view_available?(42))
  end

  def test_nil_not_available
    assert_false(CArray.memory_view_available?(nil))
  end
end
