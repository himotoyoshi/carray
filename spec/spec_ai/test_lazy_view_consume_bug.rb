# ---------------------------------------------------------------------------
# spec_ai/test_lazy_view_consume_bug.rb
#
# Renamed 2026-06-08 from test_cafake_on_cabincmp_subtract.rb to reflect
# the broader structural scope.  Tracks the lazy-view-consume bug pinned
# by the INTEROP_AUDIT phase (= devel/PROPOSAL_LAZY_ELEMENTWISE_VIEW_INTEROP_
# AUDIT.md rev4).
#
# Root cause (H9, CONFIRMED 2026-06-08):
#   ca_xfer_stride_dispatch (ext/carray_core.c:1349) の self-memcpy fast
#   path × lazy view (CABinOp/CABinCmp/CAMonOp/CAMonCmp) の attach func
#   self-fill pattern の category error.
#
# Fix (N1 + N2, landed 2026-06-08):
#   N1 = 4 lazy view attach func を view-specific xfer_stride の direct
#        call に書き換え (= dispatcher bypass)
#   N2 = dispatcher fast path に self-memcpy guard 追加 (= defense in depth)
#
# Per-data_type POST_FIX_EXPECTED values are now asserted directly (omit
# marks flipped 2026-06-08 with the N1+N2 fix landed).  Broader regression
# coverage lives in spec_ai/test_lazy_view_consume_boundary.rb.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestCAFakeOnCABinCmpSubtractLatentBug < Test::Unit::TestCase
  # Per-data_type "correct" value of `(a.gt(b)).as_<dt> - (a.lt(b)).as_<dt>`
  # for a=[1,5,3], b=[5,2,3].  Computed via the eager (non-lazy) path
  # (verified in test_eager_baseline_per_data_type below) and reproduced here
  # so Phase 6 can flip omit -> assert_equal POST_FIX_EXPECTED[dt].
  POST_FIX_EXPECTED = {
    int8:    [-1, 1, 0],
    uint8:   [255, 1, 0],                       # underflow: 0-1 = 255
    int16:   [-1, 1, 0],
    uint16:  [65535, 1, 0],
    int32:   [-1, 1, 0],
    uint32:  [4294967295, 1, 0],
    int64:   [-1, 1, 0],
    uint64:  [18446744073709551615, 1, 0],
    float32: [-1.0, 1.0, 0.0],
    float64: [-1.0, 1.0, 0.0],
  }.freeze

  BUG_OBSERVED_INT   = [0, 0, 0].freeze
  BUG_OBSERVED_FLOAT = [0.0, 0.0, 0.0].freeze

  def setup
    @a = CArray.int32(3); @a[] = [1, 5, 3]
    @b = CArray.int32(3); @b[] = [5, 2, 3]
  end

  # --- baseline: eager paths all work correctly -------------------------

  def test_eager_gt_minus_eager_lt_correct
    gt = @a.gt(@b).as_int8
    lt = @a.lt(@b).as_int8
    assert_equal [-1, 1, 0], (gt - lt).to_a
  end

  def test_eager_materialize_then_subtract_correct
    gt = @a.gt(@b).as_int8.to_ca
    lt = @a.lt(@b).as_int8.to_ca
    assert_equal [-1, 1, 0], (gt - lt).to_a
  end

  def test_lazy_individual_materialize_correct
    # Each operand, materialised on its own, yields the right values.
    gt = @a.lazy.gt(@b).as_int8
    lt = @a.lazy.lt(@b).as_int8
    assert_equal [0, 1, 0], gt.to_a
    assert_equal [1, 0, 0], lt.to_a
  end

  # --- baseline pin: eager path's per-data_type POST_FIX_EXPECTED values -----
  # This is the "ground truth" the Phase 6 fix must reproduce on the
  # lazy path.  If this assertion ever drifts, POST_FIX_EXPECTED needs
  # re-derivation before flipping the omit-marked tests below.

  POST_FIX_EXPECTED.each_key do |dt|
    define_method("test_eager_baseline_per_data_type_#{dt}") do
      ml = @a.gt(@b).__send__("as_#{dt}")
      mr = @a.lt(@b).__send__("as_#{dt}")
      assert_equal POST_FIX_EXPECTED[dt], (ml - mr).to_a,
                   "eager baseline drift for #{dt}"
    end
  end

  # --- post-fix assertion: data_type matrix verifies N1+N2 fix --------------
  # Previously omit-marked as a known latent bug; flipped 2026-06-08 with
  # the N1+N2 narrow correctness fix landed.  Each data_type's
  # `(a.lazy.gt(b)).as_<dt> - (a.lazy.lt(b)).as_<dt>` must now return the
  # POST_FIX_EXPECTED[dt] values.

  POST_FIX_EXPECTED.each_key do |dt|
    define_method("test_lazy_subtract_post_fix_#{dt}") do
      ml = @a.lazy.gt(@b).__send__("as_#{dt}")
      mr = @a.lazy.lt(@b).__send__("as_#{dt}")
      assert_equal POST_FIX_EXPECTED[dt], (ml - mr).to_a,
                   "N1+N2 fix should produce correct value for #{dt}"
    end
  end

  # --- regression: CArray#<=> uses eager path and is unaffected ---------

  def test_eager_spaceship_works
    assert_equal [-1, 1, 0], (@a <=> @b).to_a
  end

  def test_eager_spaceship_byte_parity_int8
    result = @a <=> @b
    assert_equal CA_INT8, result.data_type
  end
end
