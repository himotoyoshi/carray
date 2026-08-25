# frozen_string_literal: true
#
# spec_ai/test_f2_coverage_audit.rb
#
# Coverage audit: kernel_iterator (ca_iter_state_init_l1) が CArray の
# 全 obj_type を受け付けることを mechanical に確認。各 view class について
# 代表 instance を作り、t1_smoke で rc = OK を期待する。
#
# 接続漏れがあれば SRC_NONE → CA_ITER_ERR_NOT_CHEAP で fail する。
# 「届ける」原則: 速度最適化ではなく "kernel_iterator が view を受け付ける"
# 最低保証の test。

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestF2CoverageAudit < Test::Unit::TestCase

  OK = CArray::T1_ITER_OK

  def assert_kernel_iterator_accepts (view, label)
    r = CArray.t1_smoke(view)
    assert_equal OK, r[:rc],
                 "kernel_iterator rejected #{label} (class=#{view.class}, " \
                 "rc=#{r[:rc]})"
    assert_equal view.to_ca.dump_binary, r[:data],
                 "binary parity mismatch for #{label}"
  end

  # ==== entity / wrap / scalar ====================================

  def test_carray_entity
    assert_kernel_iterator_accepts(CArray.float64(8).seq, "CArray entity")
  end

  def test_cscalar
    s = CScalar.float64
    s[0] = 3.14
    assert_kernel_iterator_accepts(s, "CScalar")
  end

  # ==== CAStride family (single attach pointer) ===================

  def test_carefer_reshape
    a = CArray.int32(12).seq
    assert_kernel_iterator_accepts(a.reshape(3, 4), "CARefer (reshape)")
  end

  def test_cablock
    a = CArray.float64(5, 6).seq
    assert_kernel_iterator_accepts(a[1..3, 1..4], "CABlock")
  end

  def test_carepeat
    a = CArray.int32(5).seq
    assert_kernel_iterator_accepts(a[:%, 3], "CARepeat")
  end

  def test_catranspose
    a = CArray.float64(3, 4).seq
    assert_kernel_iterator_accepts(a.transpose, "CATranspose")
  end

  def test_caunbound_repeat_bound
    # CAUnboundRepeat once bound has the same attach pointer as
    # ca_stride_func (= shared typedef), reached via SRC_CASTRIDE.
    a = CArray.float64(3).seq
    ub = a.unbound_repeat(:*, nil)        # shape [1, 3]
    assert_kernel_iterator_accepts(ub, "CAUnboundRepeat (auto-bound smoke)")
  end

  # ==== descriptor framework views (SRC_DESCRIPTOR / L2_ALIASABLE) ====

  def test_cawindow
    a = CArray.float64(5, 6).seq
    assert_kernel_iterator_accepts(a.window(1..3, 1..4), "CAWindow")
  end

  def test_cashift
    a = CArray.float64(5, 6).seq
    assert_kernel_iterator_accepts(a.shift(1, 2, fill_value: 0.0), "CAShift")
  end

  def test_csa
    a = CArray.float64(5, 4).seq
    m = CA_BOOLEAN([true, false, true, false, true])
    assert_kernel_iterator_accepts(a[m, nil], "CSA (CASelectAxis)")
  end

  def test_cagrid
    a = CArray.int32(5, 5).seq
    assert_kernel_iterator_accepts(a[CA_INT([0, 2, 4]), nil], "CAGrid")
  end

  def test_caselect_1d
    a = CArray.float64(20).seq
    assert_kernel_iterator_accepts(a[a > 5.0], "CASelect")
  end

  # CAMapping was removed in R.3 (PROPOSAL_CAMAPPING_REMOVAL); a[mapper]
  # normalises to a CAStride/CAGrid chain that is already covered by the
  # CASelect / CAGrid entries above.

  # ==== SRC_ATTACH views (view-specific transform) ====================

  def test_cafake
    a = CArray.int32(8).seq
    assert_kernel_iterator_accepts(a.float64, "CAFake (cast view)")
  end

  def test_cabyte_swap
    a = CArray.int32(8).seq
    assert_kernel_iterator_accepts(a.swap_bytes, "CAByteSwap")
  end

  def test_cabitarray
    a = CArray.uint8(8).seq
    assert_kernel_iterator_accepts(a.bits, "CABitarray")
  end

  def test_cabitfield
    a = CArray.uint8(8).seq
    assert_kernel_iterator_accepts(a.bitfield(0..2, CA_UINT8), "CABitfield")
  end

  # CAReduce: covered by step 9.3 / spec_ai/test_t1_step9_src_attach.rb
  # (CAReduce has no public Ruby surface; constructed via ca_reduce_new C
  # entry).  Existing step-9 tests pin SRC_ATTACH path.  Skip here.

  # CAObject: covered by step 9.4 / spec_ai/test_t1_step9_src_attach.rb
  # (CAObject requires custom Ruby subclass with fetch_index callback to
  # produce useful data; existing step-9 tests pin the kernel_iterator
  # path through SRC_ATTACH).  Skipping here to avoid duplicate coverage.

  # ==== Composite Phase 2 views (SRC_ATTACH via F-2 follow-up) ========

  def test_catile
    a = CArray.int32(4).seq
    assert_kernel_iterator_accepts(a.tile(3), "CATile")
  end

  def test_caroll
    a = CArray.int32(5).seq
    assert_kernel_iterator_accepts(a.roll(2), "CARoll")
  end
end
