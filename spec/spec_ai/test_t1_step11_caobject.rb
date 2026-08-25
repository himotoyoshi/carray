# frozen_string_literal: true
#
# spec_ai/test_t1_step11_caobject.rb
#
# T1 step 11 — CAObject SRC_ATTACH 統合 (延長戦 final step)。
#
# CAObject (Ruby callback per-element bridge) は step 9 で landed した
# SRC_ATTACH 5 view と structural に同じ pattern (func_attach / sync /
# detach + CA_FLAG_READ_ONLY は configurable)、step 11 で
# classify_source に 1 行追加で accept。
#
# bench gate 適用外 (= Ruby callback overhead が dominant)、parity のみ
# pin。
#
# Prep doc: devel/PROPOSAL_T1_STEP11_CAOBJECT.md rev1.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end
require_relative "../../samples/caobject/link"  # CALink subclass (moved to samples/ in 3.0)

# Test fixture: writable CAObject with simple fetch/store/copy/sync
class T11WritableObj < CAObject
  def initialize
    super(CA_INT32, [4])
    @backing = [10, 20, 30, 40]
  end
  def fetch_addr(addr); @backing[addr]; end
  def store_addr(addr, val); @backing[addr] = val; end
  def copy_data(data); 4.times { |i| data[i] = @backing[i] }; end
  def sync_data(data); 4.times { |i| @backing[i] = data[i] }; end
  attr_reader :backing
end

# Readonly CAObject (= rejects WRITE through ca_is_readonly)
class T11ReadonlyObj < CAObject
  def initialize
    super(CA_FLOAT64, [4], read_only: true)
  end
  def fetch_addr(addr); Float(addr * 1.5); end
  def copy_data(data); 4.times { |i| data[i] = Float(i * 1.5) }; end
end

class TestT1Step11CAObject < Test::Unit::TestCase

  OK            = CArray::T1_ITER_OK
  ERR_READONLY  = CArray::T1_ITER_ERR_READONLY
  ALIAS_ATTACH  = CArray::T1_ITER_ALIAS_ATTACH
  ALIAS_NONE    = CArray::T1_ITER_ALIAS_NONE

  # ====================================================================
  # 1. L1 READ unmasked, parity
  # ====================================================================
  def test_caobject_l1_read_parity
    obj = T11WritableObj.new
    r = CArray.t1_smoke(obj)
    assert_equal OK,                  r[:rc]
    assert_equal ALIAS_NONE,          r[:alias_mode]  # was ALIAS_ATTACH; SRC_ATTACH uses iter-owned scratch + xfer_all since 2026-05-31
    assert_equal obj.elements,        r[:total_elems]
    assert_equal obj.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # 2. L1 READ + UNDEF cell, mask delivery
  # ====================================================================
  def test_caobject_unmasked_returns_null_mask
    # CAObject mask creation requires a subclass-defined create_mask
    # hook that wires up CAObjectMask backing — outside step 11 scope
    # (= CAObject masks form their own ecosystem).  The kernel_iterator
    # mask delivery infrastructure (step 6 ca_copy_data) is generic and
    # was already pinned by step 9 (5 view + mask) and step 10 (CARefer
    # over CAReduce mask chain).  Here we just confirm that an unmasked
    # CAObject delivers NULL mask correctly through the SRC_ATTACH path.
    obj = T11WritableObj.new
    refute obj.has_mask?, "fresh CAObject should not have mask"
    r = CArray.t1_smoke_with_mask(obj)
    assert_equal OK,    r[:rc]
    assert_equal false, r[:mask_seen]
  end

  # ====================================================================
  # 3. L2 READ parity
  # ====================================================================
  def test_caobject_l2_read_parity
    obj = T11WritableObj.new
    r = CArray.t1_smoke_strided(obj)
    assert_equal OK,                  r[:rc]
    assert_equal obj.elements,        r[:total_elems]
    assert_equal obj.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # 4. WRITE on readonly → CA_ITER_ERR_READONLY
  # ====================================================================
  def test_caobject_write_on_readonly_rejected
    obj = T11ReadonlyObj.new
    # smoke_init_rc accepts (src, flags); flags=CA_KERNEL_WRITE=1
    rc = CArray.t1_smoke_init_rc(obj, 1)
    assert_equal ERR_READONLY, rc
  end

  # ====================================================================
  # 5. WRITE on writable, scatter back via Ruby sync_data
  # ====================================================================
  def test_caobject_l1_write_sync_back
    # T11WritableObj is int32 — can't use the f64 fill smoke directly.
    # Build a float64 writable for this test.
    klass = Class.new(CAObject) do
      def initialize
        super(CA_FLOAT64, [4])
        @backing = [1.0, 2.0, 3.0, 4.0]
      end
      def fetch_addr(addr); @backing[addr]; end
      def store_addr(addr, val); @backing[addr] = val; end
      def copy_data(data); 4.times { |i| data[i] = @backing[i] }; end
      def sync_data(data); 4.times { |i| @backing[i] = data[i] }; end
      attr_reader :backing
    end
    obj = klass.new
    rc = CArray.t1_smoke_write_fill_f64(obj, 7.5)
    assert_equal OK,         rc
    assert_equal [7.5]*4,    obj.backing  # scattered back via sync_data
  end

  # ====================================================================
  # 6. CALink — real-world readonly CAObject subclass
  # ====================================================================
  def test_calink_smoke
    # CALink builds a CAObject backed by an evaluator lambda.
    a = CArray.float64(4).seq(1.0, 1.0)
    link = CALink.new(a) { |x| x * x }   # readonly CAObject
    assert link.read_only?, "CALink should be readonly"
    r = CArray.t1_smoke(link)
    assert_equal OK,                   r[:rc]
    assert_equal link.to_ca.dump_binary, r[:data]
  end
end
