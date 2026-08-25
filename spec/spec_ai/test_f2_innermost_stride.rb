# frozen_string_literal: true
#
# spec_ai/test_f2_innermost_stride.rb
#
# F-2 (PROPOSAL_F2_KERNEL_ITERATOR_ALIAS rev6): innermost-STRIDE L2 alias
# path in kernel_iterator for descriptor-routed views (CAWindow / CAShift /
# CSA / CAGrid).  Eligibility:
#   - innermost descriptor axis kind == STRIDE
#   - outer axes (= 0..ndim-2) contain no SHIFT (= F-2 minimal scope,
#     OOB fill_slab support deferred)
# When eligible the kernel_iterator skips scratch alloc and yields
# parent.ptr + outer_prefix_offset + inner_byte_start with
# inner_byte_stride as a strided slab per outer iteration.
#
# Coverage:
#   - CAWindow innermost-interior alias (= primary new win path)
#   - CSA outer-INDEX + innermost-STRIDE (multiple indirect_axis positions)
#   - CAGrid outer-INDEX + innermost-STRIDE
#   - parent = CABlock non-contig hardening
#   - fallback cases: innermost INDEX, innermost SHIFT, outer SHIFT
#   - mask propagation (= materialise mask, alias data)
# Binary parity vs view.to_ca.dump_binary in every case.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestF2InnermostStride < Test::Unit::TestCase

  OK            = CArray::T1_ITER_OK
  ALIAS_NONE    = CArray::T1_ITER_ALIAS_NONE
  ALIAS_STRIDED = CArray::T1_ITER_ALIAS_STRIDED

  # ====================================================================
  # CAWindow / CAShift — innermost-interior alias
  # ====================================================================

  def test_cawindow_all_interior_2d
    # All axes interior (= F-1 STRIDE降格 on both axes).  innermost STRIDE,
    # no outer SHIFT → L2_ALIASABLE.
    a = CArray.float64(8, 8).seq
    v = a.window(1..6, 2..5)
    assert_equal [6, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 6,             r[:slabs]
    assert_equal v.elements,    r[:total_elems]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cawindow_innermost_interior_outer_stride
    # Innermost interior STRIDE, outer also STRIDE (full range nil).
    a = CArray.int32(5, 7).seq
    v = a.window(nil, 1..5)        # axis 0 STRIDE (full), axis 1 STRIDE
    assert_equal [5, 5], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 5,             r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cawindow_innermost_shift_outer_interior_falls_back
    # Innermost axis is SHIFT (= boundary crossing): not eligible → fall
    # back to SRC_DESCRIPTOR materialise.
    a = CArray.float64(5, 5).seq
    v = a.window(1..3, -1..3, fill_value: -1.0)
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cawindow_outer_shift_innermost_interior_falls_back
    # Outer SHIFT + innermost interior STRIDE.  Pure-shape eligibility for
    # alias, but OOB fill_slab unsupported in this F-2 scope → downgrade
    # to materialise.  When F-2 OOB support lands this assertion flips.
    a = CArray.float64(5, 5).seq
    v = a.window(-1..3, 1..3, fill_value: -1.0)
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # CSA — outer-INDEX + innermost-STRIDE
  # ====================================================================

  def test_csa_indirect_axis_0_2d
    # a[mask, nil]: axis 0 INDEX, axis 1 STRIDE → L2_ALIASABLE.
    a = CArray.float64(6, 4).seq
    m = CA_BOOLEAN([true, false, true, true, false, true])
    v = a[m, nil]
    assert_equal [4, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 4,             r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_csa_indirect_axis_0_3d
    # a[mask, nil, nil]: axis 0 INDEX, axis 1/2 STRIDE → L2_ALIASABLE.
    # Outer prefix walks 2 dims: one INDEX + one STRIDE.
    a = CArray.float64(5, 3, 4).seq
    m = CA_BOOLEAN([true, false, true, true, false])
    v = a[m, nil, nil]
    assert_equal [3, 3, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 3 * 3,         r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_csa_indirect_axis_1_3d
    # a[nil, mask, nil]: axis 0 STRIDE, axis 1 INDEX, axis 2 STRIDE →
    # L2_ALIASABLE (innermost STRIDE, outer has INDEX but no SHIFT).
    a = CArray.float64(3, 5, 4).seq
    m = CA_BOOLEAN([true, false, true, true, false])
    v = a[nil, m, nil]
    assert_equal [3, 3, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 3 * 3,         r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_csa_indirect_axis_innermost_falls_back
    # a[nil, nil, mask]: axis 2 (= innermost) INDEX → not eligible,
    # materialise.
    a = CArray.float64(3, 4, 5).seq
    m = CA_BOOLEAN([true, false, true, true, false])
    v = a[nil, nil, m]
    assert_equal [3, 4, 3], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # CAGrid — outer-INDEX + innermost-STRIDE
  # ====================================================================

  def test_cagrid_outer_index_2d
    # a[CA_INT([...]), nil]: axis 0 INDEX, axis 1 STRIDE.
    a = CArray.int32(6, 5).seq
    idx = CA_INT([0, 2, 4, 5])
    v = a[idx, nil]
    assert_equal [4, 5], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 4,             r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cagrid_outer_index_3d
    # a[CA_INT(...), nil, nil]: axis 0 INDEX, axis 1/2 STRIDE.
    a = CArray.int32(5, 3, 4).seq
    idx = CA_INT([0, 2, 4])
    v = a[idx, nil, nil]
    assert_equal [3, 3, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal 3 * 3,         r[:slabs]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cagrid_innermost_index_falls_back
    # a[nil, CA_INT(...)]: axis 1 (= innermost) INDEX → not eligible.
    a = CArray.int32(4, 6).seq
    idx = CA_INT([0, 2, 4, 5])
    v = a[nil, idx]
    assert_equal [4, 4], v.dim.to_a
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # parent non-contig hardening
  # ====================================================================

  def test_csa_over_cablock_parent
    # parent itself is a CABlock view (= non-entity).  Inner alias path
    # writes parent.ptr + inner_start; parent.ptr here is the CABlock's
    # materialised buffer when attached.  Binary parity is the safety
    # net — alias data must match v.to_ca.dump_binary regardless of
    # parent kind.
    base = CArray.float64(10, 10).seq
    blk = base[2..7, 1..8]            # CABlock (parent of CSA)
    m = CA_BOOLEAN([true, false, true, true, false, true])
    v = blk[m, nil]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK, r[:rc]
    # alias mode may be STRIDED (CABlock attach is contig in current
    # impl) or NONE (if engine falls back); either way binary parity.
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # mask propagation — alias data + materialise mask (rev6 §4.4)
  # ====================================================================

  def test_csa_with_mask_data_alias_mask_materialise
    a = CArray.float64(5, 4).seq
    a.mask = 0
    a[0, 1] = UNDEF
    a[2, 3] = UNDEF
    m = CA_BOOLEAN([true, false, true, true, false])
    v = a[m, nil]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    # data binary parity covers both unmasked cells + arbitrary contents
    # at masked positions (mask delivered separately via t1_smoke_strided's
    # internal mask gather, not exposed in :data).
    assert_equal v.to_ca.dump_binary, r[:data]
  end
end
