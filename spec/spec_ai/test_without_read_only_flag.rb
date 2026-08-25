require "test/unit"
require "carray"

# Tests for CArray#without_read_only_flag { ... } — private, block-scoped
# READONLY lift used by interop bridges (canonical example: attaching a
# validity mask onto the read-only CAWrap returned by wrap_memory_view).
#
# Contract (see devel/PROPOSAL_WITHOUT_READ_ONLY_FLAG.md):
#   - block-only, rb_ensure guarantees the flag is restored on both normal
#     return and raise
#   - self only (does not walk parent chains, does not touch ca->mask flags)
#   - private visibility, invoked via send(:without_read_only_flag)
#   - direct mask= remains readonly-strict; only the bridge escape passes

class TestWithoutReadOnlyFlag < Test::Unit::TestCase

  # (1) Positive path: read-only entity + block-scoped mask= succeeds,
  #     flag restored on block exit, mask readable afterwards.
  def test_block_scoped_mask_attach
    w = CArray.int32(5) { |i| i }
    w.set_read_only_flag
    assert_true(w.read_only?, "precondition: read-only")
    mask = CArray.boolean(5) { |i| i.even? }

    w.send(:without_read_only_flag) do
      w.mask = mask
    end

    assert_true(w.read_only?, "flag restored after block")
    assert_true(w.has_mask?, "mask attached inside block")
    # boolean bulk to_a emits Integer 0/1 (BOOL2OBJ), not true/false
    assert_equal([true, false, true, false, true], w.mask.to_a)
  end

  # (2) Public API unchanged: direct .mask= on a read-only entity still
  #     raises. The primitive does not weaken the general guarantee.
  def test_direct_mask_assign_on_readonly_still_raises
    w = CArray.int32(3) { |i| i }
    w.set_read_only_flag
    assert_raise(RuntimeError) do
      w.mask = CArray.boolean(3) { false }
    end
  end

  # (3) Exception safety: if the block raises, ensure clause restores
  #     the flag before propagating.
  def test_flag_restored_on_exception_in_block
    w = CArray.int32(4) { |i| i }
    w.set_read_only_flag

    assert_raise(CArray::DataTypeError) do
      w.send(:without_read_only_flag) do
        # An uncastable value raises DataTypeError partway through mask=
        w.mask = "not a mask"
      end
    end

    assert_true(w.read_only?, "flag restored even after raise")
  end

  # (4) Idempotency on an already-writable entity: no accidental flag flip.
  def test_writable_entity_stays_writable
    w = CArray.int32(3) { |i| i }
    refute(w.read_only?, "precondition: writable")

    result = w.send(:without_read_only_flag) do
      w[0] = 99
      "body-return"
    end

    refute(w.read_only?, "flag unchanged on writable entity")
    assert_equal("body-return", result, "block value is returned")
    assert_equal(99, w[0])
  end

  # (5) Frozen check: rb_check_frozen runs before yielding, so a frozen
  #     array raises FrozenError, not the block body.
  def test_frozen_raises_frozen_error
    w = CArray.int32(3) { |i| i }
    w.freeze
    assert_raise(FrozenError) do
      w.send(:without_read_only_flag) { flunk("block should not run") }
    end
  end

  # (6) Private visibility: direct call (no send) raises NoMethodError.
  def test_private_visibility
    w = CArray.int32(3) { |i| i }
    assert_raise(NoMethodError) do
      w.without_read_only_flag { }
    end
  end

  # (7) No block: rb_need_block raises LocalJumpError.
  def test_no_block_raises
    w = CArray.int32(3) { |i| i }
    w.set_read_only_flag
    assert_raise(LocalJumpError) do
      w.send(:without_read_only_flag)
    end
  end

  # A read-only chunk carrying a validity bitmap, in the shape an interop
  # bridge hands one over: values plus LSB-first bits, 1 = present.  The mask
  # is attached through the primitive, exactly as the bridge does after
  # wrap_memory_view returns a read-only CAWrap.
  def read_only_chunk (values)
    v = CA_INT32(values.map { |x| x.nil? ? 0 : x })
    v.set_read_only_flag
    if values.any?(&:nil?)
      bytes = CArray.uint8((values.length + 7) / 8) { 0 }
      values.each_with_index do |x, i|
        bytes[i / 8] |= (1 << (i % 8)) unless x.nil?
      end
      v.send(:without_read_only_flag) do
        v.mask = (~bytes).bitarray[0...values.length]
      end
    end
    v
  end

  # (8) Bridge end-to-end: read-only chunk with nulls → mask attach via the
  #     primitive → correct masked values, flag intact throughout.
  def test_read_only_chunk_mask_attach_end_to_end
    v = read_only_chunk([10, nil, 30, nil, 50])

    assert_true(v.read_only?, "wrap still read-only after mask attach")
    assert_true(v.has_mask?, "mask attached")
    assert_equal([false, true, false, true, false], v.mask.to_a)
    assert_equal([10, 30, 50], v[:is_not_masked].to_a)
  end

  # (9) CAMeld composition: two nullable chunks held read-only with masks
  #     attached via the primitive, melded along axis 0.  Verifies CAMeld
  #     reads parent masks correctly (no write-back to read-only parents).
  def test_cameld_over_masked_readonly_wraps
    w1 = read_only_chunk([1, nil, 3])
    w2 = read_only_chunk([nil, 5])
    mm = CArray.meld(w1, w2, axis: 0)

    assert_instance_of(CAMeld, mm)
    assert_true(mm.read_only?, "CAMeld over read-only parents is read-only")
    assert_true(mm.has_mask?, "mask propagated from parents")
    assert_equal([false, true, false, true, false], mm.mask.to_a)
    # 1 + 3 + 5 = 9; masked cells skipped
    assert_in_delta(9.0, mm.sum.to_f, 1e-12)
  end
end
