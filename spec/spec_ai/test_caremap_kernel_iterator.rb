# frozen_string_literal: true
#
# spec_ai/test_caremap_kernel_iterator.rb
#
# M.6: CARemap acceptance by kernel_iterator (SRC_ATTACH path).
#
# CARemap is internal-only so we drive the iterator via dedicated C
# smoke helpers t1_smoke_remap_{read,read_strided,write_fill_f64}.
# Expected alias_mode = ALIAS_NONE (= iter-owned scratch + xfer_all).
#
# Parity check: gathered data must equal
#   ref.flatten[idx.flatten.to_a].pack('q*')   for CA_SIZE
# or the f64/i32 equivalent dumped via the same per-element gather.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestCARemapKernelIterator < Test::Unit::TestCase

  OK             = CArray::T1_ITER_OK
  ALIAS_NONE     = CArray::T1_ITER_ALIAS_NONE

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims); a[] = values; a
  end

  # Expected byte buffer for view.flat[k] = ref.flat[idx.flat[k]].
  def expected_bytes (ref, idx)
    ref_flat = ref.flatten
    idx_flat = idx.flatten
    out      = CArray.new(ref.data_type, [idx.elements])
    idx_flat.elements.times do |k|
      out[k] = ref_flat[idx_flat[k]]
    end
    out.dump_binary
  end

  # ------------------------------------------------------------ L1 READ

  def test_l1_read_1d_f64
    ref = CArray.float64(5).seq
    idx = mk_idx([5], [4, 2, 0, 3, 1])
    r = CArray.t1_smoke_remap_read(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal idx.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  def test_l1_read_2d_int32
    ref = CArray.int32(2, 3).seq + 10
    idx = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    r = CArray.t1_smoke_remap_read(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal 6, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  def test_l1_read_3d
    ref = CArray.float64(2, 2, 2).seq
    idx = mk_idx([2, 2, 2], [7, 6, 5, 4, 3, 2, 1, 0])
    r = CArray.t1_smoke_remap_read(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal 8, r[:total_elems]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  def test_l1_read_through_view_parent
    # ref itself is a transpose view
    base = CArray.int32(3, 4).seq
    ref  = base.farray
    idx  = mk_idx([4, 3], (0..11).to_a)
    r = CArray.t1_smoke_remap_read(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal 12, r[:total_elems]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  # ------------------------------------------------------------ L2 READ (strided)

  def test_l2_read_1d_f64
    ref = CArray.float64(5).seq
    idx = mk_idx([5], [4, 2, 0, 3, 1])
    r = CArray.t1_smoke_remap_read_strided(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal idx.elements, r[:total_elems]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  def test_l2_read_2d_int32
    ref = CArray.int32(3, 4).seq
    idx = mk_idx([3, 4], (0..11).to_a.reverse)
    r = CArray.t1_smoke_remap_read_strided(ref, idx)
    assert_equal OK, r[:rc]
    assert_equal 12, r[:total_elems]
    assert_equal expected_bytes(ref, idx), r[:data]
  end

  # ------------------------------------------------------------ WRITE round-trip

  def test_l1_write_fill_f64_permutation
    ref = CArray.float64(5).fill(0.0)
    idx = mk_idx([5], [4, 2, 0, 3, 1])
    rc = CArray.t1_smoke_remap_write_fill_f64(ref, idx, 7.5)
    assert_equal OK, rc
    # Identity coverage — every cell of ref gets written through some
    # idx position.
    assert_equal [7.5, 7.5, 7.5, 7.5, 7.5], ref.to_a
  end

  def test_l1_write_partial_idx_only_touches_targets
    ref = CArray.float64(5).fill(-1.0)
    idx = mk_idx([5], [0, 2, 4, 0, 2])           # leaves ref[1], ref[3] untouched
    rc = CArray.t1_smoke_remap_write_fill_f64(ref, idx, 9.5)
    assert_equal OK, rc
    assert_equal [9.5, -1.0, 9.5, -1.0, 9.5], ref.to_a
  end

  # ------------------------------------------------------------ classify_source acceptance

  def test_remap_is_classified_as_src_attach
    # Construct, run smoke, check rc == OK + alias_mode == ALIAS_NONE
    # which together prove classify_source returned SRC_ATTACH (otherwise
    # init_l1 would have returned ERR_SRC).
    ref = CArray.int32(3).seq
    idx = mk_idx([3], [0, 1, 2])
    r = CArray.t1_smoke_remap_read(ref, idx)
    assert_equal OK, r[:rc],
                 "kernel_iterator did not accept CARemap as source"
    assert_equal ALIAS_NONE, r[:alias_mode]
  end

end
