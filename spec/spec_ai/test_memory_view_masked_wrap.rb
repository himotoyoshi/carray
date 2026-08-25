require "test/unit"
require "carray"

# PROPOSAL_MV_MASKED_WRAP: wrap/from_memory_view with paired mask buffer.
# These tests use CArrays as both data and mask MV producers; the path is
# identical for any PEP 3118 producer pair (numpy.ma data + mask buffers,
# Arrow validity bitmap → byte mask, etc.).

class TestMemoryViewMaskedWrap < Test::Unit::TestCase

  # ============================================================
  # wrap_memory_view(data, mask:) — zero-copy paired wrap
  # ============================================================

  def test_wrap_with_mask_basic
    data = CArray.uint8(2, 3) { |i, j| i * 10 + j }
    mask = CArray.boolean(2, 3) { |i, j| (i + j).odd? ? 1 : 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    assert_kind_of(CAWrap, w)
    assert_equal(true, w.has_mask?)
    assert_equal([2, 3], w.shape)
    assert_equal(data.to_a, w.value.to_a)
    assert_equal(mask.to_a, w.mask.to_a)
  end

  def test_wrap_with_mask_data_write_propagates
    data = CArray.int32(4) { |i| i }
    mask = CArray.boolean(4) { 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    w[2] = 999
    assert_equal(999, data[2], "data write through wrap must reach source buffer")
  end

  def test_wrap_with_mask_mask_write_propagates
    data = CArray.int32(4) { |i| i }
    mask = CArray.boolean(4) { 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    w[1] = UNDEF
    assert_equal(true, mask[1], "UNDEF write through wrap must reach source mask buffer")
  end

  def test_wrap_with_mask_external_mask_change_visible
    data = CArray.uint16(3) { |i| i + 10 }
    mask = CArray.boolean(3) { 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    assert_equal(false, w.mask[0])
    mask[0] = 1
    assert_equal(true, w.mask[0],
                 "mask buffer change must be visible through the wrap (zero-copy)")
  end

  def test_wrap_with_mask_nil_keyword_equals_unmasked
    data = CArray.int32(3) { |i| i }
    w_default = CArray.wrap_memory_view(data)
    w_nil = CArray.wrap_memory_view(data, mask: nil)
    assert_equal(false, w_default.has_mask?)
    assert_equal(false, w_nil.has_mask?,
                 "mask: nil must match the default (unmasked) path byte-for-byte")
  end

  # ============================================================
  # wrap_memory_view(data, mask:) — validation rejects
  # ============================================================

  def test_wrap_with_mask_shape_mismatch_raises
    data = CArray.int32(3, 4)
    mask = CArray.boolean(3, 5)  # wrong shape
    assert_raise(ArgumentError) do
      CArray.wrap_memory_view(data, mask: mask)
    end
  end

  def test_wrap_with_mask_ndim_mismatch_raises
    data = CArray.int32(3, 4)
    mask = CArray.boolean(12)  # right elements, wrong ndim
    assert_raise(ArgumentError) do
      CArray.wrap_memory_view(data, mask: mask)
    end
  end

  def test_wrap_with_mask_wrong_dtype_raises
    data = CArray.int32(3)
    mask = CArray.int32(3)  # i, not ?/B/b
    assert_raise(ArgumentError) do
      CArray.wrap_memory_view(data, mask: mask)
    end
  end

  def test_wrap_with_mask_strided_mask_raises
    # A transposed mask is a non-contiguous view; wrap with mask: must
    # reject it (v1 contig-only constraint).
    data = CArray.uint8(3, 4) { |i, j| i * 4 + j }
    full_mask = CArray.boolean(4, 3) { 0 }
    strided_mask = full_mask.transpose  # shape (3,4), strided
    refute(strided_mask.memory_view_available?,
           "sanity: transposed view should be non-trivial MV") rescue nil
    assert_raise(ArgumentError) do
      CArray.wrap_memory_view(data, mask: strided_mask)
    end
  end

  def test_wrap_with_mask_unknown_kwarg_raises
    data = CArray.int32(3)
    mask = CArray.boolean(3) { 0 }
    assert_raise(ArgumentError) do
      CArray.wrap_memory_view(data, mask: mask, junk: 42)
    end
  end

  # ============================================================
  # from_memory_view(data, mask:) — copy paired
  # ============================================================

  def test_from_with_mask_basic_copy
    data = CArray.uint8(2, 3) { |i, j| i * 10 + j }
    mask = CArray.boolean(2, 3) { |i, j| (i + j).odd? ? 1 : 0 }
    c = CArray.from_memory_view(data, mask: mask)
    refute_kind_of(CAWrap, c)
    assert_equal(true, c.has_mask?)
    assert_equal(data.to_a, c.value.to_a)
    assert_equal(mask.to_a, c.mask.to_a)
  end

  def test_from_with_mask_copy_is_independent
    data = CArray.int32(3) { |i| i + 1 }
    mask = CArray.boolean(3) { |i| i == 1 ? 1 : 0 }
    c = CArray.from_memory_view(data, mask: mask)
    data[0] = 999
    mask[0] = 1
    assert_equal(1, c[0], "copy must be independent of source data after the call")
    assert_equal(false, c.mask[0],
                 "copy must be independent of source mask after the call")
  end

  def test_from_with_mask_non_zero_coerced_to_one
    # Pass a uint8 mask (CA_BOOLEAN ≡ int8_t, same item_size=1) with
    # values 0, 5, 0, 200 — copy variant should coerce non-zero to 1.
    data = CArray.int32(4) { |i| i }
    mask = CArray.uint8(4)
    mask[0] = 0; mask[1] = 5; mask[2] = 0; mask[3] = 200
    c = CArray.from_memory_view(data, mask: mask)
    assert_equal([false, true, false, true], c.mask.to_a)
  end

  def test_from_with_mask_shape_mismatch_raises
    data = CArray.int32(3)
    mask = CArray.boolean(4)
    assert_raise(ArgumentError) do
      CArray.from_memory_view(data, mask: mask)
    end
  end

  # ============================================================
  # lifecycle: GC + re-wrap stability
  # ============================================================

  def test_wrap_with_mask_survives_gc
    data = CArray.uint8(8) { |i| i }
    mask = CArray.boolean(8) { |i| i.even? ? 1 : 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    GC.start
    GC.start
    assert_equal(data.to_a, w.value.to_a)
    assert_equal(mask.to_a, w.mask.to_a)
  end

  def test_wrap_with_mask_can_be_collected
    data = CArray.uint8(8) { |i| i }
    mask = CArray.boolean(8) { 0 }
    100.times do
      w = CArray.wrap_memory_view(data, mask: mask)
      assert_equal(data.to_a, w.value.to_a)
    end
    GC.start
    # If holders weren't released cleanly we'd see refcount leaks; the
    # smoke is "no crash + data unchanged".
    assert_equal((0...8).to_a, data.to_a)
  end

end
