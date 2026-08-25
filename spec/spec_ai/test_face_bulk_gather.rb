# spec_ai/test_face_bulk_gather.rb
#
# Regression test for the Face-rooted CAStride chain bulk-gather bug.
# Reported by another worker 2026-06-10.
#
# Symptom (pre-fix): CARecord (Face) -> CABlock -> CAField chain, bulk
# path returned wrong values (= heap copy 48 bytes when 24 expected).
# Per-cell access (f.to_a) was unaffected.
#
# Root cause: ca_stride_compose_to_root (ext/ca_obj_stride.c:275) had
# no case for Face, so compose stopped at the Face boundary.  The
# partial materialise branch (ext/ca_obj_stride.c:773-779) then called
# `ca_xfer_stride(face_root, ...)` which delegated via ca_face_xfer_stride
# straight to the entity's xfer_stride.  The entity's dispatcher
# (ca_xfer_stride_dispatch -> ca_xfer_strided_walk) used the ENTITY's
# bytes (= CARecord FIXLEN bytes, e.g. 16 for GeoCoord) as the memcpy
# cell size, not the LEAF's bytes (= 8 for an f64 field) -> bytes
# mismatch -> wrong data + heap overflow.
#
# Fix: Face is layout-identity over its parent (= byte-for-byte alias
# via ca_face_attach, same data_type / bytes / strides).  Walk through
# Face as an identity step in ca_stride_compose_to_root so the
# composed (strides, base) carry into parent's space unchanged.  Then
# root becomes the underlying entity, ca_is_attached(root) is true,
# the hot path fires (ca_stride_xfer_with_layout) which reads
# `ca->bytes` from the LEAF (= correct).
#
# Scope: covers both the reporter's exact scenario (= first-field,
# byte_offset == 0) AND the residual sub-element offset case
# (= second-or-later field, byte_offset > 0 over a CABlock chain)
# fixed by PROPOSAL_CASTRIDE_COMPOSE_SUB_ELEMENT.md (2026-06-10
# follow-up to d967f95).  Sub-element offset is now captured in
# ca_stride_compose_through and folded into out_base.

require "test/unit"
require "carray"

class TestFaceBulkGather < Test::Unit::TestCase
  GeoCoord = CArray.struct { float64 :lat; float64 :lng }

  def setup
    @pts = CARecord.new(GeoCoord, 4)
    @pts["lat"][] = [30.0, 31.0, 32.0, 33.0].to_ca
    @pts["lng"][] = [10.0, 11.0, 12.0, 13.0].to_ca
  end

  # The original reporter's minimal scenario (= first field "lat",
  # byte_offset 0, range [0..2]).
  def test_face_chain_bulk_gather_byte_correctness
    sl = @pts[0..2]    # CARecord (Face) wrapping CABlock
    f  = sl["lat"]     # CAField on CABlock (R.6 Face strip)

    expected = [30.0, 31.0, 32.0]
    assert_equal expected, f.to_a              # per-cell (passed pre-fix)
    assert_equal expected, f.copy.to_a         # bulk via ca_copy_data
    assert_equal expected, f.dump_binary.unpack("D*")  # bulk via xfer_all
    assert_equal [15.0, 15.5, 16.0], (f * 0.5).to_a   # bulk via binop
  end

  # Reporter's scenario with a non-zero range start (different base_offset
  # on the CABlock layer, still first field).
  def test_face_chain_bulk_gather_offset_range
    sl = @pts[1..3]
    f  = sl["lat"]
    expected = [31.0, 32.0, 33.0]
    assert_equal expected, f.to_a
    assert_equal expected, f.copy.to_a
    assert_equal expected, f.dump_binary.unpack("D*")
  end

  # Full-range first field over the bare CARecord (= no CABlock in
  # between).  Confirms direct Face -> CAField path is unaffected.
  def test_face_direct_field_bulk_gather
    f = @pts["lat"]
    expected = [30.0, 31.0, 32.0, 33.0]
    assert_equal expected, f.to_a
    assert_equal expected, f.copy.to_a
    assert_equal expected, f.dump_binary.unpack("D*")
  end

  # Second field (lng) over bare CARecord — the direct Face path
  # (= no CABlock interposed) works at all byte_offsets because there
  # is no leaf.base_offset % parent.bytes != 0 issue to trip on.
  def test_face_direct_second_field_bulk_gather
    f = @pts["lng"]
    expected = [10.0, 11.0, 12.0, 13.0]
    assert_equal expected, f.to_a
    assert_equal expected, f.copy.to_a
    assert_equal expected, f.dump_binary.unpack("D*")
  end

  # Residual sub-element offset case fixed by
  # PROPOSAL_CASTRIDE_COMPOSE_SUB_ELEMENT.md.  Bulk gather on lng
  # (= byte_offset 8 within a 16-byte record) over a CABlock'd
  # CARecord chain previously returned [0.0, 11.0, 0.0] due to
  # ca_stride_compose_through rejecting `leaf.base_offset % parent.bytes != 0`.
  def test_face_chain_bulk_gather_second_field
    sl = @pts[0..2]
    f  = sl["lng"]
    expected = [10.0, 11.0, 12.0]
    assert_equal expected, f.to_a
    assert_equal expected, f.copy.to_a
    assert_equal expected, f.dump_binary.unpack("D*")
    assert_equal [20.0, 22.0, 24.0], (f * 2.0).to_a
  end

  # Same as above but with a non-zero range start (= CABlock has its
  # own non-zero base_offset; the sub-element offset must compose
  # additively).
  def test_face_chain_bulk_gather_lng_offset_range
    sl = @pts[1..3]
    f  = sl["lng"]
    expected = [11.0, 12.0, 13.0]
    assert_equal expected, f.to_a
    assert_equal expected, f.copy.to_a
    assert_equal expected, f.dump_binary.unpack("D*")
    assert_equal [22.0, 24.0, 26.0], (f * 2.0).to_a
  end

  # Cross-check: both fields readable from the same sliced chain.
  def test_face_chain_both_fields_bulk_gather
    sl = @pts[1..3]
    assert_equal [31.0, 32.0, 33.0], sl["lat"].copy.to_a
    assert_equal [11.0, 12.0, 13.0], sl["lng"].copy.to_a
  end
end
