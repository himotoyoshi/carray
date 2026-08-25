# frozen_string_literal: true
#
# spec_ai/test_f2_followup_tile_roll.rb
#
# F-2 follow-up: CATile / CARoll を kernel_iterator に SRC_ATTACH pattern
# で接続したことを pin。per-cell modulo wrap が descriptor framework の
# kind enum {STRIDE, INDEX, SHIFT} に乗らないため innermost-STRIDE L2
# alias path には乗らないが、SRC_ATTACH 経由で kernel_iterator が view を
# 受け付ける (= 「届ける」原則上の穴を埋める)。
#
# 期待挙動:
#   - rc = OK (= 旧 SRC_NONE での reject が解消)
#   - alias_mode = ALIAS_ATTACH (= step 9 SRC_ATTACH と同じ)
#   - binary parity vs view.to_ca

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestF2FollowupTileRoll < Test::Unit::TestCase

  OK           = CArray::T1_ITER_OK
  ALIAS_ATTACH = CArray::T1_ITER_ALIAS_ATTACH
  ALIAS_NONE   = CArray::T1_ITER_ALIAS_NONE

  # ====================================================================
  # CATile
  # ====================================================================

  def test_catile_1d_l1
    a = CArray.int32(4).seq
    v = a.tile(3)               # parent=[0,1,2,3] -> [0,1,2,3,0,1,2,3,0,1,2,3]
    assert_equal [12], v.dim.to_a
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_catile_2d_l1
    a = CArray.float64(3, 2).seq
    v = a.tile(2, 3)
    assert_equal [6, 6], v.dim.to_a
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_catile_1d_l2_via_attach_strided
    a = CArray.int32(4).seq
    v = a.tile(3)
    # bench-grade kernel_iterator dispatch via L2
    total = CArray.t1_smoke_attach_strided(v)
    assert_equal v.elements, total
  end

  # ====================================================================
  # CARoll
  # ====================================================================

  def test_caroll_1d_l1
    a = CArray.int32(5).seq
    v = a.roll(2)               # [0,1,2,3,4] -> [3,4,0,1,2]
    assert_equal [5], v.dim.to_a
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_caroll_2d_l1
    a = CArray.float64(4, 5).seq
    v = a.roll(1, 2)
    assert_equal [4, 5], v.dim.to_a
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_caroll_l2_via_attach_strided
    a = CArray.int32(5, 4).seq
    v = a.roll(2, 1)
    total = CArray.t1_smoke_attach_strided(v)
    assert_equal v.elements, total
  end

  # ====================================================================
  # mask propagation (= same path as other SRC_ATTACH views)
  # ====================================================================

  def test_catile_with_mask
    a = CArray.float64(4).seq
    a.mask = 0
    a[1] = UNDEF
    v = a.tile(2)
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_caroll_with_mask
    a = CArray.float64(5).seq
    a.mask = 0
    a[0] = UNDEF
    a[3] = UNDEF
    v = a.roll(2)
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal ALIAS_NONE, r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal v.to_ca.dump_binary, r[:data]
  end
end
