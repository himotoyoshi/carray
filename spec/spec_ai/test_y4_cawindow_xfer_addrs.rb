# Y.4 (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CAWindow xfer_addrs
# interior-only fast path.  Uses embed descriptor + Y.1.e compose-to-root
# resolver to dispatch sub-region gather through axis_dispatch engine,
# skipping per-cell bounds-normalise loop.  Non-interior windows and
# CAShift OOB cases preserved via legacy per-cell path.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY4CAWindowXferAddrs < Test::Unit::TestCase

  def setup
    @entity = CArray.int64(50, 40)
    50.times { |i| 40.times { |j| @entity[i, j] = i * 1000 + j } }
  end

  # ---- Interior CAWindow (fast path) ----

  def test_interior_window_whole_view_get
    win = @entity.window(5..40, 4..30)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end

  def test_interior_window_whole_view_put_round_trip
    target = @entity.dup
    win = target.window(5..40, 4..30)
    payload = CArray.int64(win.dim[0], win.dim[1])
    win.dim[0].times { |i| win.dim[1].times { |j| payload[i, j] = -1000 - i * 10 - j } }
    addrs = (0...win.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(win, addrs, payload.dump_binary)
    assert_equal payload.to_a, win.to_a
  end

  def test_interior_window_get_against_ruby_lookup
    win = @entity.window(2..45, 1..38)
    addrs = (0...win.elements).to_a
    got_bytes = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    expected = (0...win.elements).map { |a| win[a / win.dim[1], a % win.dim[1]] }.pack("q<*")
    assert_equal expected, got_bytes
  end

  # ---- Boundary-crossing CAWindow (legacy path: OOB needs per-cell) ----

  def test_boundary_window_whole_view_get_uses_legacy
    # window straddling parent boundary -> some cells OOB, fast path skipped
    win = @entity.window(-3..45, -2..40, fill_value: -99)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end

  def test_boundary_window_byte_parity_with_to_ca
    # Use to_ca as reference for OOB handling (legacy path correctness)
    win = @entity.window(-2..2, -1..2, fill_value: -777)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end

  # ---- CAShift with fill_value: Y.4 ext path (embed_eligible drops covers_all req) ----

  def test_shift_with_fill_uses_fast_path
    sh = @entity.shift(1, -1, fill_value: 0)
    addrs = (0...sh.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sh, addrs, 1)
    assert_equal sh.to_ca.dump_binary, got
  end

  def test_shift_with_fill_put_interior_only
    # PUT through shift: OOB cells silently dropped (= matches §4.3 spec);
    # interior cells write through to parent.  Compare interior cells only.
    target = @entity.dup
    sh = target.shift(1, -1, fill_value: 0)
    payload = CArray.int64(sh.dim[0], sh.dim[1])
    sh.dim[0].times { |i| sh.dim[1].times { |j| payload[i, j] = 9_000_000 + i * 100 + j } }
    addrs = (0...sh.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(sh, addrs, payload.dump_binary)
    # Interior: shift(1, -1) means output row i takes parent row i-1, col j takes parent col j+1.
    # OOB: output row 0 (parent row -1) and output col 39 (parent col 40).
    (1...sh.dim[0]).each do |i|
      (0...sh.dim[1] - 1).each do |j|
        assert_equal payload[i, j], target[i - 1, j + 1], "interior (#{i},#{j}) write should reach parent"
      end
    end
  end

  def test_boundary_window_with_fill_fast_path
    win = @entity.window(-2..40, -1..30, fill_value: -777)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end

  # ---- Arbitrary addrs: legacy path ----

  def test_interior_window_random_addrs
    win = @entity.window(5..40, 4..30)
    addrs = [37, 5, 199, 2, 700, 11, 0, 555]
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    expected = addrs.map { |a| win[a / win.dim[1], a % win.dim[1]] }.pack("q<*")
    assert_equal expected, got
  end

  def test_interior_window_empty_addrs
    win = @entity.window(5..40, 4..30)
    got = CArray.bench_xfer_addrs_get_addrs(win, [], 1)
    assert_equal "", got
  end

  # ---- Interior window over virtual CARefer (Y.1.e cascade) ----

  def test_interior_window_over_flatten_parent
    # window over flat 1-D virtual parent
    flat = @entity.flatten
    win = flat.window(100..1500)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end

  # ---- Different data_types ----

  def test_interior_window_float64
    parent = CArray.float64(30, 20)
    30.times { |i| 20.times { |j| parent[i, j] = i * 0.25 + j * 0.0625 } }
    win = parent.window(3..25, 2..15)
    addrs = (0...win.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(win, addrs, 1)
    assert_equal win.to_ca.dump_binary, got
  end
end
