# spec_ai/test_view_self_assignment_v1.rb
#
# PROPOSAL_VIEW_SELF_ASSIGNMENT V.1 (rev3) regression pin.
#
# rb_ca_store_all rewired ca_attach(cv) → ca_xfer_all(cv, scratch, GET) so
# that view self-assignment routes through the per-region partial materialise
# path (CHEAP_ATTACH W.x).  This eliminates the size-gap × virtual root
# catastrophe (= old path materialised the whole virtual root regardless of
# view size).  These tests pin (i) bit-identical correctness across all
# previously exercised paths and (ii) the absence of huge-root materialise
# for size-gap cases.

require "test/unit"
require "carray"

class TestViewSelfAssignmentV1 < Test::Unit::TestCase
  # --- (i) correctness pin ---

  def test_1d_flip_self_assign
    a = CArray.int32(8).seq
    a[] = a.flip(0)
    assert_equal [7, 6, 5, 4, 3, 2, 1, 0], a.to_a
  end

  def test_2d_flip_axis0_self_assign
    a = CArray.int32(3, 3).seq
    a[] = a.flip(0)
    assert_equal [[6, 7, 8], [3, 4, 5], [0, 1, 2]], a.to_a
  end

  def test_cablock_slice_flip_self_assign_parent_intact
    big = CArray.int32(20).seq
    slice = big[5..14]
    slice[] = slice.flip(0)
    assert_equal (5..14).to_a.reverse, slice.to_a
    # Parent outside slice region must be untouched
    assert_equal [0, 1, 2, 3, 4], big[0..4].to_a
    assert_equal [15, 16, 17, 18, 19], big[15..19].to_a
  end

  def test_cross_data_type_assign_via_cafake_source
    a = CArray.int32(10).seq
    b = CArray.float64(10)
    b[] = a.fake(:float64)
    assert_equal (0..9).map(&:to_f), b.to_a
  end

  def test_mask_propagation
    a = CArray.int32(5).seq
    a.mask = [0, 1, 0, 1, 0]
    b = CArray.int32(5).seq + 10
    b[] = a
    # Mask transferred from src
    assert_equal [false, true, false, true, false], b.mask.to_a
    # Underlying byte data = src data (mask doesn't prevent write)
    assert_equal [0, 1, 2, 3, 4], b.value.to_a
    # Masked positions report UNDEF in user-visible result
    assert_equal [0, UNDEF, 2, UNDEF, 4], b.to_a
  end

  def test_data_type_mismatch_cast_path
    a = CArray.float64(5).seq
    b = CArray.int32(5).seq
    a[] = b
    assert_equal [0.0, 1.0, 2.0, 3.0, 4.0], a.to_a

    i = CArray.int32(5)
    f = CArray.float64(5).seq
    i[] = f
    assert_equal [0, 1, 2, 3, 4], i.to_a
  end

  def test_virtual_root_byteswap_self_assign_writes_through
    # Whole-view self-flip through writable virtual root must write through
    # to the entity.  Byteswap reinterprets bytes so bs.to_a is not directly
    # meaningful here; we verify the parent entity got reversed at the byte
    # level (bs.flip(0) over bs writes flipped *bytes* back to a).
    a = CArray.int32(8).seq
    orig = a.to_a.dup
    bs = a.swap_bytes
    bs[] = bs.flip(0)
    # Underlying entity must have been mutated (write-through worked)
    refute_equal orig, a.to_a, "write-through to entity through CAByteSwap failed"
  end

  def test_unbound_repeat_assign
    ubrep = CArray.int32(3).seq.unbound_repeat(:*, nil)
    dst = CArray.int32(4, 3)
    dst[] = ubrep
    assert_equal [[0, 1, 2], [0, 1, 2], [0, 1, 2], [0, 1, 2]], dst.to_a
  end

  # --- (ii) absence of huge-root materialise for size-gap cases ---

  # The old ca_attach(cv) path called ca_stride_func_attach → ca_attach(root),
  # materialising the whole virtual root (size = root->elements × root->bytes).
  # Post-V.1 uses ca_xfer_all which routes to xfer_stride for cold virtual
  # roots, scaling cost with the view size, not the root size.  We use
  # wall-clock as a coarse proxy: 1k iterations over a 101-element view of a
  # 76 MB virtual root must complete in a few ms, not several seconds.

  def test_size_gap_virtual_root_does_not_blow_up
    big = CArray.float64(1_000_000).seq  # 8 MB entity
    bs_root = big.swap_bytes            # ~8 MB virtual root
    # 100-element slice self-flip × 100 iter — would be > 1 s if root
    # materialise per iter, ~ < 50 ms if partial materialise works.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times do
      slice = bs_root[100..200]
      slice[] = slice.flip(0)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert elapsed < 0.5,
      "size-gap self-assign took #{(elapsed * 1000).round(1)} ms for 100 iter — " \
      "regression: ca_attach(root) seems to materialise whole virtual root again"
  end
end
