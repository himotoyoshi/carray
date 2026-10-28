require "test/unit"
require "carray"

# Regression: a generic multi-d CAStride view (reshape / transpose that ADDS
# axes vs the root) over a *lazy per-element-transform* boundary root
# (CAMonOp from swap_bytes / as_type, CAFake from fake, CABinOp) must
# materialise only the touched span of the root, not the whole root.
#
# Before the fix, ca_stride_func_xfer_all's partial-materialise path only
# handled ca->ndim == root->ndim (and ndim < via the axis-drop bridge), so a
# reshape(n,2) over a 1-D lazy root (ndim 2 > root ndim 1) fell to the
# whole-root 2-pass fallback -- cost O(root) per view, quadratic across a
# per-record loop (found via gridplot-gshhg: 8000 features x whole file =
# 21.7s vs 0.007s with an entity root).
#
# See devel/PROPOSAL_LAZY_ROOT_PARTIAL_MATERIALIZE.md.
class TestLazyRootPartialMaterialize < Test::Unit::TestCase

  # --- correctness: view result == materialized-root result ------------

  # Force the same lazy op onto an entity root (.copy the transform first),
  # so any divergence is the partial-materialise path, not the transform.
  def assert_view_matches(mono, ref, msg, &op)
    assert_equal op.call(ref).to_a, op.call(mono).to_a, msg
  end

  def test_reshape_over_monop_root
    raw  = CArray.int32(4000) { |i| i * 3 - 7 }
    mono = raw.swap_bytes             # CAMonOp
    ref  = raw.swap_bytes.copy        # same values, entity root
    assert_equal CAMonOp, mono.class
    assert_view_matches(mono, ref, "reshape(20,2)")   { |r| r[[100, 40]].reshape(20, 2).copy }
    assert_view_matches(mono, ref, "reshape 3-D")     { |r| r[[100, 120]].reshape(20, 3, 2).copy }
    assert_view_matches(mono, ref, "transpose")       { |r| r[[100, 40]].reshape(2, 20).transpose.copy }
    assert_view_matches(mono, ref, "flip reshape")    { |r| r[[100, 40]].reshape(20, 2)[-1..0, nil].copy }
    assert_view_matches(mono, ref, "reshape+colslice"){ |r| r[[100, 80]].reshape(20, 4)[nil, 1..2].copy }
  end

  def test_reshape_over_fake_root
    raw  = CArray.int32(4000) { |i| i }
    fake = raw.fake(:float64)         # CAFake
    ref  = raw.fake(:float64).copy
    assert_equal CAFake, fake.class
    assert_view_matches(fake, ref, "fake f64 reshape") { |r| r[[100, 40]].reshape(20, 2).copy }
  end

  # store (PUT) through a reshape-over-lazy view writes the right bytes.
  def test_store_from_reshape_over_lazy_root
    raw  = CArray.int32(4000) { |i| i * 7 + 1 }
    mono = raw.swap_bytes
    ref  = raw.swap_bytes.copy
    got  = CArray.int32(20, 2) { 0 }; got[nil, nil]  = mono[[100, 40]].reshape(20, 2)
    want = CArray.int32(20, 2) { 0 }; want[nil, nil] = ref[[100, 40]].reshape(20, 2)
    assert_equal want.to_a, got.to_a
  end

  # A write through a reshape over a 1-D cold root reaches only the cells
  # it addresses.  Sending the root's span back would write the cells
  # between them too: a tile's stale copy of a cell would land after the
  # one written, and a lossy root would bring them back changed.
  def test_write_through_reshape_over_cold_root_reaches_only_its_cells
    r = CArray.int32(3).seq!
    r.tile(2).reshape(3, 2)[0..2, 0..0] = CA_INT32([[10], [20], [30]])
    assert_equal [10, 30, 20], r.to_a
    r = CArray.int32(3).seq!
    r.tile(2).reshape(3, 2)[nil, 0] = CA_INT32([10, 20, 30])
    assert_equal [10, 30, 20], r.to_a
    r = CArray.int32(6).seq!
    v = r.swap_bytes.swap_bytes.reshape(3, 2)
    v[2, 1] = 8
    v[0..1, 0..0] = CA_INT32([[9], [7]])
    assert_equal [9, 1, 7, 3, 4, 8], r.to_a
  end

  # --- performance: cost scales with the view, not the root -----------
  #
  # The defining property of the fix. A fixed-size view over a root grown
  # 100x must not grow ~100x in time. Lenient bound (< 8x) to stay robust
  # against noise while still catching the O(root) regression (which was
  # ~100x here).
  def test_cost_independent_of_root_size
    n = 20
    small = 50_000
    large = 5_000_000
    copy_view = lambda do |root_elems|
      mono = CArray.int32(root_elems) { |i| i & 0x3ff }.swap_bytes
      v = mono[[100, n * 2]].reshape(n, 2)
      best = Float::INFINITY
      5.times do
        GC.start
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        300.times { v.copy }
        best = [best, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0].min
      end
      best
    end
    t_small = copy_view.call(small)
    t_large = copy_view.call(large)
    ratio = t_large / t_small
    assert_operator ratio, :<, 8.0,
      "small-view cost over a #{large}-elem lazy root grew #{ratio.round(1)}x " \
      "vs a #{small}-elem root -- O(root) regression (whole-root materialise)"
  end
end
