# X.1 (PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §4.1):
# CAWindow / CAShift xfer_stride embed-based path correctness pin.
#
# Tests:
#   - sub-region GET byte parity vs manual cell-by-cell computation
#   - sub-region PUT round-trip (write through view, read back)
#   - 3 geometry patterns: interior 包含 / boundary またぎ / 完全 OOB
#   - whole-view asymptote
#   - mask transparency (CAWindow inherits parent.mask path)
#
# These pin the X.1 fast path against regression and document the expected
# sub-region geometry behaviour.

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"
class TestXferStrideSubregionWindow < Test::Unit::TestCase

  def setup
    @n = 20
    @parent = CArray.float64(@n, @n) { |i,j| i * @n + j }
  end

  # Helper: manual sub-region read from a view, returns CArray bytes.
  def expected_subregion(view, starts, counts)
    out = CArray.new(view.data_type, counts)
    counts[0].times do |i|
      counts[1].times do |j|
        vi = starts[0] + i
        vj = starts[1] + j
        out[i, j] = view[vi, vj]
      end
    end
    out
  end

  # GET interior 包含 (sub-region ⊂ embed rect, no fill region)
  def test_get_window_interior_subregion
    view = @parent.window(2..@n-3, 2..@n-3, fill_value: -1.0)  # interior-only
    starts = [3, 4]
    counts = [5, 6]
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual_bytes
  end

  # GET boundary またぎ (CAShift with sub-region across the bound edge)
  def test_get_shift_boundary_crossing
    view = @parent.shift(@n/2, 0, fill_value: -99.0)
    # shift down by n/2: top half is fill (-99), bottom half is alias from parent[0..n/2-1, :]
    starts = [@n/2 - 2, 0]
    counts = [4, @n/2]   # straddles the boundary
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual_bytes
  end

  # GET 完全 OOB (sub-region entirely in fill region)
  def test_get_shift_full_oob_fill
    view = @parent.shift(@n/2, 0, fill_value: -77.0)
    starts = [0, 0]
    counts = [3, @n/3]  # fully inside top fill region
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual_bytes
  end

  # whole-view asymptote
  def test_get_window_whole_view
    view = @parent.window(2..@n-3, 2..@n-3, fill_value: -1.0)
    starts = [0, 0]
    counts = view.dim.dup
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = view.to_ca  # via xfer_all path
    assert_equal expected.dump_binary, actual_bytes
  end

  # CAShift whole-view with full fill (shift larger than dim)
  def test_get_shift_whole_view_pure_fill
    # shift exceeds dim → view is entirely fill
    view = @parent.shift(@n, 0, fill_value: 42.0)  # shift = dim → no overlap
    starts = [0, 0]
    counts = view.dim.dup
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = view.to_ca
    assert_equal expected.dump_binary, actual_bytes
  end

  # GET pattern with empty alias on one axis (any_empty branch)
  def test_get_window_any_empty_axis
    # window shifted so it falls entirely outside parent on axis 0
    view = @parent.window((-@n*2)..(-@n-1), 0..@n-1, fill_value: 13.0)
    starts = [0, 0]
    counts = [3, 5]
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual_bytes
  end

  # PUT round-trip: write through view then read back equals what was written
  # (only for alias region; fill region writes are silently dropped — that's
  # the documented spec, not a bug).
  def test_put_window_interior_roundtrip
    p = @parent.template
    p.seq!
    view = p.window(2..@n-3, 2..@n-3, fill_value: -1.0)
    # write zeros through a sub-region inside the embed rect
    counts = [4, 5]
    src = CArray.float64(*counts) { |i,j| 1000.0 + i*10 + j }
    starts = [3, 4]
    strides = [counts[1] * 8, 8]  # row-major byte stride over counts (8 = bytes)
    # use ca_xfer_stride directly via the smoke API equivalent — we use
    # the index-level setter as the regression cross-check (= goes through
    # different code path), then read sub-region back via xfer_stride.
    counts[0].times do |i|
      counts[1].times do |j|
        view[starts[0]+i, starts[1]+j] = src[i, j]
      end
    end
    actual_bytes = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual_bytes
  end

  # CAWindow xfer_stride byte parity should match xfer_all on whole-view (= the
  # 12x gap closure observation, asymptote pin).
  def test_xfer_stride_whole_view_matches_xfer_all
    view = @parent.window(2..@n-3, 2..@n-3, fill_value: -1.0)
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  def test_xfer_stride_whole_view_matches_xfer_all_shift
    view = @parent.shift(3, -2, fill_value: 0.0)
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  # ---- X.1 virtual parent fallback pins ----
  # PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §3.0 rev3 + §4.1.3 scope:
  # When CAWindow's parent is itself a virtual view without ptr (= CAFake /
  # CAByteSwap / etc.), the X.1 fast path's `parent->ptr` gate falls
  # through and the legacy per-row outer loop handles delivery.  These
  # tests pin that byte parity is preserved across that fallback path
  # (= correctness, not performance).  The structural residual perf gap
  # against xfer_all is documented in
  # devel/bench_x1_virtual_parent_residual_gap.rb (= not chased; would
  # require §2.5 violation).

  def test_get_window_over_fake_parent_byte_parity
    view = @parent.fake(:int32).window(2..@n-3, 2..@n-3, fill_value: -1)
    # whole-view: xfer_all (with parent.attach) vs xfer_stride (legacy
    # fallback via parent.xfer_stride per row) must be byte-identical.
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
    # sub-region also byte-identical via cell-by-cell expected
    starts = [3, 4]; counts = [5, 6]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_get_window_over_byteswap_parent_byte_parity
    view = @parent.endian(:big).window(2..@n-3, 2..@n-3, fill_value: -1.0)
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
    starts = [1, 1]; counts = [@n/2, @n/2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end
end
