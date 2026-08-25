# frozen_string_literal: true
#
# spec_ai/test_t1_step10_carefer_hardening.rb
#
# T1 step 10 — CARefer hardening test matrix.
#
# CARefer was already accepted by kernel_iterator via SRC_CASTRIDE
# since step 1-8 (ca_func[CA_OBJ_REFER].attach == ca_stride_func.attach
# routes it through the CAStride family path).  This file pins the
# untested paths from that landing:
#
# - case 3 (Spanned, view.bytes > parent.bytes) where view.mask is
#   CARefer over a CAReduce mask0 — exercises step 6 ca_copy_data
#   over a CAReduce parent for the first time
# - case 2 (Divided, view.bytes < parent.bytes) where mask0 is CARepeat
# - case 1 (Simple, view.bytes == parent.bytes) regression
# - chained parent (CABlock → CARefer case 3) — compose-fold robustness
# - WRITE × masked partial-write semantics
#
# Test matrix (~22 cases, prep doc §3.1):
# - case 3: L1/L2 × R/W × {unmasked, masked} = 8 cases
# - case 1/2 READ: L1/L2 × {unmasked, masked} = 8 cases
# - case 1/2 WRITE L1 only: 4 cases
# - chained parent (CABlock × case 3 × masked) = 1 case
# - WRITE skip semantics edge = 1 case
#
# Prep doc: devel/PROPOSAL_T1_STEP10_CAREFER_HARDENING.md rev1.1.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestT1Step10CARefHardening < Test::Unit::TestCase

  OK            = CArray::T1_ITER_OK
  ALIAS_CONTIG  = CArray::T1_ITER_ALIAS_CONTIG

  # ====================================================================
  # case 3 (Spanned): uint8[16] → float32[4]
  #   - view.bytes (4) > parent.bytes (1), ratio = 4
  #   - mask = CARefer over CAReduce (OR of 4 parent mask bits)
  # ====================================================================

  def build_case3
    parent = CArray.uint8(16)
    16.times { |i| parent[i] = i + 1 }
    [parent, parent.refer(CA_FLOAT32, [4])]
  end

  def attach_mask_to(parent, bits)
    parent.mask = CArray.boolean(parent.elements)
    bits.each { |i| parent.mask[i] = 1 }
  end

  def test_case3_l1_read_unmasked
    parent, view = build_case3
    r = CArray.t1_smoke(view)
    assert_equal OK,                  r[:rc]
    assert_equal ALIAS_CONTIG,        r[:alias_mode]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case3_l1_read_masked
    parent, view = build_case3
    attach_mask_to(parent, [2, 5, 7, 10])
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    assert_equal true, r[:mask_seen]
    # Expected per-view-cell mask: OR of every 4 parent bits
    # parent.mask = [F F T F F T F T F F T F F F F F]
    # view.mask   = [T, T, T, F] = [1, 1, 1, 0]
    assert_equal [1, 1, 1, 0], r[:mask_bytes].bytes
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  def test_case3_l1_write_unmasked
    parent, view = build_case3
    view[nil] = 2.5
    # After view[]=, each parent[i*4..i*4+3] holds float32 LE pattern of 2.5
    # We then re-walk via kernel_iterator (READ) and confirm binary parity.
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
    assert_equal [2.5]*4, view.to_a
  end

  def test_case3_l1_write_masked
    # Step 6 §7.3: mask structure is parent-owned; kernel writes through
    # alias but masked-cell writes are conceptually skipped by the kernel
    # itself (using CA_FOR_EACH_UNMASKED).  Here we use direct view[]=
    # which doesn't honor mask (it overwrites everything), so the test
    # just confirms parity post-write + that mask survives.
    parent, view = build_case3
    attach_mask_to(parent, [2, 5, 7, 10])
    view[nil] = 0.0
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    # mask still reflects the original parent bits, gathered into view shape
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  def test_case3_l2_read_unmasked
    parent, view = build_case3
    r = CArray.t1_smoke_strided(view)
    assert_equal OK,                  r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case3_l2_read_masked
    parent, view = build_case3
    attach_mask_to(parent, [2, 5, 7, 10])
    r = CArray.t1_smoke_strided(view)
    # L2 smoke doesn't currently expose mask, but it must not crash and
    # must yield correct data slabs.  Mask delivery via L2 is exercised
    # in test_case3_l1_read_masked (L1 path uses the same scratch_mask
    # mechanism as L2 init_l2 SRC_CASTRIDE).
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case3_l2_write_unmasked
    parent, view = build_case3
    rc = CArray.t1_smoke_write_fill_strided_f64(view, 1.0) rescue :type_err
    # view is float32, the f64 fill smoke type-checks — confirm reject
    assert_equal :type_err, rc
    # WRITE via view[]= as a proxy for L2 dispatch correctness
    view[nil] = 3.5
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case3_l2_write_masked
    # Note: Ruby `view[nil] = val` clears the mask of written cells
    # (CArray semantics).  The test pins the *L2 dispatch + parity*
    # after such a write — mask values change to reflect the cleared
    # state, and kernel_iterator's mask delivery must agree with
    # view.to_ca.mask.
    parent, view = build_case3
    attach_mask_to(parent, [0, 1, 2, 3])
    view[nil] = 4.0
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
    # view[]= cleared the mask (CArray semantics), confirm consistency:
    assert_equal [false, false, false, false], view.mask.to_a
  end

  # ====================================================================
  # case 2 (Divided): uint32[4] → uint8[16]
  #   - view.bytes (1) < parent.bytes (4), ratio = 4
  #   - mask = CARefer over CARepeat (each parent mask bit replicated 4x)
  # ====================================================================

  def build_case2
    parent = CArray.uint32(4).seq(0x01020304, 0x01010101)
    [parent, parent.refer(CA_UINT8, [16])]
  end

  def test_case2_l1_read_unmasked
    _parent, view = build_case2
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case2_l1_read_masked
    parent, view = build_case2
    parent.mask = CArray.boolean(4)
    parent.mask[1] = 1; parent.mask[3] = 1
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    # CARepeat: parent.mask[i] replicated 4× = expected view.mask
    # = [F×4, T×4, F×4, T×4]
    expected = [0]*4 + [1]*4 + [0]*4 + [1]*4
    assert_equal expected, r[:mask_bytes].bytes
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  def test_case2_l2_read_unmasked
    _parent, view = build_case2
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case2_l2_read_masked
    parent, view = build_case2
    parent.mask = CArray.boolean(4)
    parent.mask[0] = 1
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case2_l1_write_unmasked
    _parent, view = build_case2
    view[nil] = 0xAB
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case2_l1_write_masked
    parent, view = build_case2
    parent.mask = CArray.boolean(4)
    parent.mask[1] = 1
    view[nil] = 0xCD
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  # ====================================================================
  # case 1 (Simple reshape): uint32[2,3] → uint32[6]
  #   - view.bytes == parent.bytes, ratio = 1
  #   - mask = CARefer over parent.mask directly
  # ====================================================================

  def build_case1
    parent = CArray.uint32(2, 3).seq
    [parent, parent.refer(CA_UINT32, [6])]
  end

  def test_case1_l1_read_unmasked
    _parent, view = build_case1
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case1_l1_read_masked
    parent, view = build_case1
    parent.mask = CArray.boolean(2, 3)
    parent.mask[0, 1] = 1; parent.mask[1, 2] = 1
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    # Direct copy: parent.mask reshaped to view shape
    # parent.mask = [[F,T,F],[F,F,T]] → flat = [0,1,0,0,0,1]
    assert_equal [0, 1, 0, 0, 0, 1], r[:mask_bytes].bytes
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  def test_case1_l2_read_unmasked
    _parent, view = build_case1
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case1_l2_read_masked
    parent, view = build_case1
    parent.mask = CArray.boolean(2, 3)
    parent.mask[0, 0] = 1
    r = CArray.t1_smoke_strided(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case1_l1_write_unmasked
    _parent, view = build_case1
    view[nil] = 999
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.dump_binary, r[:data]
  end

  def test_case1_l1_write_masked
    parent, view = build_case1
    parent.mask = CArray.boolean(2, 3)
    parent.mask[1, 1] = 1
    view[nil] = 42
    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    assert_equal view.to_ca.mask.to_type(:int8).to_a, r[:mask_bytes].bytes
  end

  # ====================================================================
  # chained parent (CABlock → case 3 → mask)
  #   - non-contig CABlock as CARefer's parent
  #   - case 3 reinterpret on top
  #   - mask path goes through CABlock + CAReduce composition
  # ====================================================================

  def test_chained_block_case3_masked
    big = CArray.uint8(4, 16).seq
    big.mask = CArray.boolean(4, 16)
    # Set distinctive mask pattern in rows 1..2 (the slice we'll take)
    big.mask[1, 5]  = 1
    big.mask[2, 0]  = 1
    big.mask[2, 11] = 1
    block = big[1..2, nil]   # CABlock, non-contig row slice
    assert_equal CABlock, block.class

    # case 3 reinterpret over CABlock: uint8[2,16] → float32[2,4]
    view = block.refer(CA_FLOAT32, [2, 4])
    assert_equal CARefer, view.class

    r = CArray.t1_smoke_with_mask(view)
    assert_equal OK, r[:rc]
    assert_equal true, r[:mask_seen]
    # Reference: view.to_ca.mask (which exercises the full
    # block → CAReduce → CARefer chain materialisation)
    assert_equal view.to_ca.mask.to_type(:int8).to_a.flatten, r[:mask_bytes].bytes
  end

  # ====================================================================
  # WRITE skip semantics edge — masked cell write through kernel_iterator
  # ====================================================================

  def test_case3_write_via_kernel_iter_mask_preserved
    # Pin step 6 §7.3 invariant: kernel_iterator WRITE through alias
    # writes to parent.ptr directly (memcpy path) and does NOT touch
    # the mask structure — mask remains parent-owned.  This contrasts
    # with Ruby `view[]=`, which CArray semantics clears the mask of
    # written cells.
    parent = CArray.float64(4).seq(1.0, 1.0)
    parent.mask = CArray.boolean(4)
    parent.mask[1] = 1
    view = parent.refer(CA_FLOAT64, [4])   # case 1 (same bytes)
    rc = CArray.t1_smoke_write_fill_f64(view, 7.0)
    assert_equal OK, rc
    # Mask preserved (= kernel_iterator did NOT clear it, unlike view[]=)
    assert_equal [false, true, false, false], parent.mask.to_a
    # Raw data updated everywhere (smoke fill kernel doesn't honor mask
    # — that's the kernel author's choice via CA_FOR_EACH_UNMASKED).
    # parent.to_a honors the mask and renders the masked cell as UNDEF.
    assert_equal [7.0, UNDEF, 7.0, 7.0], parent.to_a
    # Raw bytes via dump_binary confirm the write reached all cells
    # (= the alias-write path doesn't honor mask, it's a raw memcpy):
    assert_equal [7.0]*4, parent.dump_binary.unpack("D*")
  end
end
