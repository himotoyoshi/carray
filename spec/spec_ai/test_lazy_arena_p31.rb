# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 3 (P.3.1 + P.3.2 + P.3.3) —
# arena slot-pool tests.
#
# Pin properties:
#   1. ca_xfer_all (= universal materialise entry) enter/exit balances
#      depth back to 0 after every to_ca.
#   2. All slots are returned to in_use=0 after to_ca completes (= no
#      slot leak).
#   3. Second and subsequent to_ca calls REUSE warm slots from the
#      first call (= no fresh xmalloc, the Phase 3 perf-win signature).
#   4. Mid-loop GC does not break arena (slots survive GC sweeps).
#   5. Phase 2 trapping-op masked-zero divisor SIGFPE avoidance
#      remains intact (= load-bearing #2 invariant from prep doc rev3
#      §3.2).
#   6. Affine view wrapping lazy view (e.g. transpose, block, refer)
#      still routes through ca_xfer_all and arena is entered/exited
#      correctly — load-bearing #2 universal-entry fix from rev2/3 §3.3.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyArenaP31 < Test::Unit::TestCase

  # ------------------------------------------------- depth balance --

  def test_depth_returns_to_zero_after_to_ca
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq + 1
    _ = (a.lazy + b).to_ca
    assert_equal 0, CArray.__lazy_arena_depth__,
                 "ca_xfer_all enter/exit must balance"
  end

  def test_all_slots_released_after_to_ca
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq + 1
    c = CArray.float64(64).seq + 2
    d = CArray.float64(64).seq + 3
    _ = (((a.lazy + b) + c) + d).to_ca
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "all arena slots must be in_use=0 after to_ca"
  end

  # ----------------------------------------- slot reuse (Phase 3 win) --

  def test_second_call_reuses_warm_slot
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq + 1
    # warm up the arena
    _ = (a.lazy + b).to_ca
    # measure the second call: xmalloc must NOT increase
    xm_before = CArray.__lazy_arena_xmalloc_count__
    reuse_before = CArray.__lazy_arena_reuse_count__
    _ = (a.lazy + b).to_ca
    xm_after = CArray.__lazy_arena_xmalloc_count__
    reuse_after = CArray.__lazy_arena_reuse_count__
    assert_equal xm_before, xm_after,
                 "second to_ca must NOT xmalloc (= slot reuse)"
    assert_operator reuse_after, :>, reuse_before,
                    "second to_ca must increment reuse counter"
  end

  def test_left_leaning_chain_reuses_single_slot
    # Left-leaning `((a+b)+c)+d` releases scratch before each next
    # binop's xfer_stride begins, so a single 8MB slot serves all 3
    # binops via the freelist.  After warm-up, no xmalloc per call.
    a = CArray.float64(1000).seq
    b = CArray.float64(1000).seq + 1
    c = CArray.float64(1000).seq + 2
    d = CArray.float64(1000).seq + 3
    # warm-up
    _ = (((a.lazy + b) + c) + d).to_ca
    # measure
    CArray.__lazy_arena_reset_counters__
    _ = (((a.lazy + b) + c) + d).to_ca
    assert_equal 3, CArray.__lazy_arena_acquire_count__,
                 "depth-3 chain must do 3 arena acquires"
    assert_equal 0, CArray.__lazy_arena_xmalloc_count__,
                 "warm chain must NOT xmalloc (= pure reuse)"
    assert_equal 3, CArray.__lazy_arena_reuse_count__,
                 "all 3 acquires must be slot reuse"
  end

  # ---------------------- Phase 2 regression — masked-zero divisor --

  def test_int_div_masked_zero_divisor_still_no_sigfpe
    # rev3 §3.2 load-bearing #2: integer DIV with masked-zero divisor
    # must build a slab mask and skip; arena replacement must NOT
    # disturb this branch.
    a = CArray.int32(8).seq + 10
    b = CArray.int32(8).seq
    b[0] = UNDEF
    out = (a.lazy / b).to_ca  # MUST NOT crash
    expected = a / b
    assert_equal expected.to_a, out.to_a
    assert_kind_of UndefClass, out[0]
  end

  # ----------------------- universal entry — affine wraps lazy --

  def test_arena_hook_fires_through_affine_wrapping_lazy
    # rev2/3 §3.3 load-bearing #2: the arena lifetime hook lives at
    # ca_xfer_all (= universal materialise entry), so even when the
    # outermost view is an affine wrapper around a lazy view, the
    # arena's enter/exit fires correctly and leaves the depth + slot
    # state clean.
    #
    # NOTE: byte-parity of (lazy + b).transpose.to_ca is a separate
    # Phase 2 design question (CABinOp::xfer_stride currently assumes
    # row-major scratch strides, and CATranspose's xfer_all requests
    # non-row-major slabs from its parent — pre-existing limitation,
    # tracked outside Phase 3 scope).  This test asserts ONLY the
    # arena lifecycle: depth balances back to 0, slots return to
    # in_use=0.
    a = CArray.float64(4, 4).seq
    b = CArray.float64(4, 4).seq + 1
    begin
      _ = (a.lazy + b).transpose.to_ca
    rescue StandardError
      # tolerate Phase 2 limitation if it raises; the lifecycle
      # invariant still holds via _exit on the exception path.
    end
    assert_equal 0, CArray.__lazy_arena_depth__,
                 "arena depth must balance even through affine wrap of lazy"
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "arena slots must release even through affine wrap of lazy"
  end

  # ------------------------------ GC stress — arena survives GC --

  def test_arena_survives_gc
    # Force GC inside a loop; the arena's xmalloc'd slot buffers are
    # held by C-level state and must NOT be reclaimed.
    a = CArray.float64(1000).seq
    b = CArray.float64(1000).seq + 1
    _ = (a.lazy + b).to_ca  # warm
    xm_pre_gc = CArray.__lazy_arena_xmalloc_count__
    10.times do
      GC.start
      _ = (a.lazy + b).to_ca
    end
    xm_post_gc = CArray.__lazy_arena_xmalloc_count__
    assert_equal xm_pre_gc, xm_post_gc,
                 "arena slots must survive GC (no fresh xmalloc)"
  end

  # -------------------------- exception path (Phase 3 rev5 補修) --

  def test_arena_depth_recovers_from_exception_in_xfer_all
    # Phase 3 rev5 fix: rb_ensure around ca_xfer_all guarantees
    # _exit even when the kernel/xfer_stride raises mid-flight.  R3
    # reset (= slot in_use=0 at depth==0 entry) then collects any
    # leaked in_use bits on the next clean call.  Regression test
    # for the silent failure mode discovered during Phase 4 P.4.1
    # (= test_caobject_partial_region intentional raise polluted
    # arena depth, breaking depth==0 invariant in this suite).
    klass = Class.new(CAObject) do
      def initialize
        super(CA_FLOAT64, 1, [4])
      end

      def copy_data(data)
        raise "intentional raise from copy_data"
      end
    end

    begin
      _ = klass.new.to_ca
    rescue StandardError
      # expected
    end

    # Next clean call: depth must balance via rb_ensure and arena
    # must be reusable (R3 reset wipes any leaked in_use bit).
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq
    _ = (a.lazy + b).to_ca

    assert_equal 0, CArray.__lazy_arena_depth__,
                 "rb_ensure must restore depth==0 after exception"
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "R3 must reset in_use=0 at next depth==0 entry"
  end
end
