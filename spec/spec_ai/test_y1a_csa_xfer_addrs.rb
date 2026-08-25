# Y.1.a (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CASelectAxis
# xfer_addrs slot opportunistic axis_dispatch fast path.
#
# Pins byte parity for whole-view (= production hot, dominant-true mask)
# and arbitrary addrs (= legacy per-cell remap preserved).

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY1aCASelectAxisXferAddrs < Test::Unit::TestCase

  def setup
    @parent = CArray.int64(10, 8)
    10.times { |i| 8.times { |j| @parent[i, j] = i * 100 + j } }
    @mask = CArray.boolean(10)
    10.times { |i| @mask[i] = (i.odd? ? 1 : 0) }
  end

  # ---- Whole-view sequential (= production hot path) ----

  def test_csa_whole_view_get_matches_xfer_all
    csa = @parent[@mask, nil]   # 5x8 CASelectAxis
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end

  def test_csa_whole_view_put_round_trip
    csa = @parent.dup[@mask, nil]
    payload = CArray.int64(csa.dim[0], csa.dim[1])
    csa.dim[0].times { |i| csa.dim[1].times { |j| payload[i, j] = 7000 + i * 10 + j } }
    addrs = (0...csa.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(csa, addrs, payload.dump_binary)
    assert_equal payload.to_a, csa.to_a
  end

  def test_csa_dominant_true_mask_increment
    # ca[:is_not_masked] += v with no mask -> whole-view sequential via CASelect.
    # CSA path: ca[true_mask, nil] += v exercises CASelectAxis xfer_addrs.
    a = @parent.dup
    full_true = CArray.boolean(10) { 1 }
    expected = (0...10).map { |i| (0...8).map { |j| a[i, j] + 12 } }
    a[full_true, nil] += 12
    assert_equal expected, a.to_a
  end

  # ---- Sub-region / partial / arbitrary addrs (legacy path) ----

  def test_csa_subregion_sequential_uses_legacy_correctness
    csa = @parent[@mask, nil]
    addrs = (3...10).to_a   # sub-region of view, < elements
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    # Compute expected via per-cell ca[addr] lookups
    expected = addrs.map { |a| csa[a / 8, a % 8] }.pack("q<*")
    assert_equal expected, got
  end

  def test_csa_random_addrs_correctness
    csa = @parent[@mask, nil]
    addrs = [37, 5, 19, 2, 28, 11]   # random within elements
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    expected = addrs.map { |a| csa[a / 8, a % 8] }.pack("q<*")
    assert_equal expected, got
  end

  def test_csa_empty_addrs
    csa = @parent[@mask, nil]
    got = CArray.bench_xfer_addrs_get_addrs(csa, [], 1)
    assert_equal "", got
  end

  # ---- Virtual parent fall-back (legacy path preserved) ----

  def test_csa_with_cafake_parent_falls_through_legacy
    # CAFake parent has no ptr -> fast path gate (parent->ptr) skipped,
    # legacy per-cell remap runs, correctness preserved.
    parent_fake = @parent.fake(:float64)
    csa = parent_fake[@mask, nil]
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end

  # ---- Different parent data_types ----

  def test_csa_float64_parent_whole_view
    parent = CArray.float64(10, 8)
    10.times { |i| 8.times { |j| parent[i, j] = i * 0.5 + j * 0.125 } }
    csa = parent[@mask, nil]
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end

  def test_csa_uint8_parent_whole_view
    parent = CArray.uint8(10, 8)
    10.times { |i| 8.times { |j| parent[i, j] = (i * 8 + j) & 0xff } }
    csa = parent[@mask, nil]
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end

  # ---- AP-axis sub-range CSA (a[mask, 2..6]) ----

  def test_csa_with_ap_subrange_whole_view
    csa = @parent[@mask, 2..6]   # 5x5 CSA with AP axis sub-range
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end
end
