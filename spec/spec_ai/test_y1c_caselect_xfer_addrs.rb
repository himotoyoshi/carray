# Y.1.c (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CASelect xfer_addrs
# slot opportunistic axis_dispatch fast path.  Pins byte parity for
# whole-view (production hot, chain a[idx_2d] via CASelect) and arbitrary
# addrs (legacy path).

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY1cCASelectXferAddrs < Test::Unit::TestCase

  def setup
    @parent = CArray.int64(10, 8)
    10.times { |i| 8.times { |j| @parent[i, j] = i * 100 + j } }
  end

  # ---- Whole-view sequential (= production hot path) ----

  def test_select_2d_mask_whole_view_get
    # CASelect = 1-D filter over flat parent
    mask = CArray.boolean(10, 8)
    10.times { |i| 8.times { |j| mask[i, j] = ((i + j) % 3 == 0 ? 1 : 0) } }
    sel = @parent[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  def test_select_whole_view_put_round_trip
    parent = @parent.dup
    mask = CArray.boolean(10, 8)
    10.times { |i| 8.times { |j| mask[i, j] = ((i + j) % 2 == 0 ? 1 : 0) } }
    sel = parent[mask]
    payload = CArray.int64(sel.elements)
    sel.elements.times { |k| payload[k] = -1000 - k }
    addrs = (0...sel.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(sel, addrs, payload.dump_binary)
    assert_equal payload.to_a, sel.to_a
  end

  def test_select_all_true_mask_get
    # dominant-true (all-true) mask: entire parent selected
    parent = @parent
    mask = CArray.boolean(10, 8) { 1 }
    sel = parent[mask]
    assert_equal parent.elements, sel.elements
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  # ---- Arbitrary / partial addrs (legacy path correctness) ----

  def test_select_random_addrs_correctness
    mask = CArray.boolean(10, 8)
    10.times { |i| 8.times { |j| mask[i, j] = 1 } }
    sel = @parent[mask]   # all 80 elements
    addrs = [37, 5, 19, 2, 70, 11, 0, 79]
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    expected = addrs.map { |a| sel[a] }.pack("q<*")
    assert_equal expected, got
  end

  def test_select_empty_addrs
    mask = CArray.boolean(10, 8) { 1 }
    sel = @parent[mask]
    got = CArray.bench_xfer_addrs_get_addrs(sel, [], 1)
    assert_equal "", got
  end

  # ---- Virtual parent fall-back ----

  def test_select_with_cafake_parent_falls_through_legacy
    parent_fake = @parent.fake(:float64)
    mask = CArray.boolean(10, 8)
    10.times { |i| 8.times { |j| mask[i, j] = ((i * j) % 4 == 0 ? 1 : 0) } }
    sel = parent_fake[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  # ---- Multi-data_type ----

  def test_select_float64_parent
    parent = CArray.float64(10, 8)
    10.times { |i| 8.times { |j| parent[i, j] = i * 0.25 + j * 0.0625 } }
    mask = CArray.boolean(10, 8)
    10.times { |i| 8.times { |j| mask[i, j] = (i % 2 == 0 ? 1 : 0) } }
    sel = parent[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  def test_select_uint8_parent
    parent = CArray.uint8(10, 8)
    10.times { |i| 8.times { |j| parent[i, j] = (i * 8 + j) & 0xff } }
    mask = CArray.boolean(10, 8) { 1 }
    sel = parent[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end
end
