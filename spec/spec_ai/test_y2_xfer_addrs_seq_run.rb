# Y.2 (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4.1):
# sequential-run detection in ca_xfer_addrs_dispatch.
#
# These tests pin byte parity for the sequential-run fast path and for
# the legacy per-cell fallback (= arbitrary / non-sequential addrs).
# Catches off-by-one in detection (= silent data corruption risk per
# §7 risk record).

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY2XferAddrsSequentialRun < Test::Unit::TestCase

  N = 64

  def setup
    @ca = CArray.int64(N).tap { |i| i[] = i * 10 + 1 }
    @bytes = @ca.bytes
  end

  # ---- GET path: byte parity for sequential / non-sequential ----

  def test_whole_view_sequential_get_matches_dump_binary
    addrs = (0...N).to_a
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    assert_equal @ca.dump_binary, got
  end

  def test_subregion_sequential_get_triggers_fast_path
    # [k..k+m-1] form: sequential run, should hit Y.2 fast path
    addrs = (10...40).to_a
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    expected = (10...40).map { |i| [@ca[i]].pack("q<") }.join
    assert_equal expected, got
  end

  def test_single_element_sequential_get
    addrs = [42]
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    assert_equal [@ca[42]].pack("q<"), got
  end

  def test_empty_addrs_get
    # n==0 short-circuit, no detection needed
    got = CArray.bench_xfer_addrs_get_addrs(@ca, [], 1)
    assert_equal "", got
  end

  def test_reverse_order_get_uses_per_cell_loop
    # Reverse [N-1, N-2, ..., 0] is NOT sequential ascending, falls to per-cell
    addrs = (0...N).to_a.reverse
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    expected = addrs.map { |i| [@ca[i]].pack("q<") }.join
    assert_equal expected, got
  end

  def test_random_addrs_get_uses_per_cell_loop
    addrs = [5, 17, 3, 42, 1, 60, 11, 8]
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    expected = addrs.map { |i| [@ca[i]].pack("q<") }.join
    assert_equal expected, got
  end

  def test_partial_sequential_then_jump_uses_per_cell_loop
    # First 10 elements sequential, last differs by 2 (pathological mid-detect)
    addrs = (0..9).to_a + [11]
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    expected = addrs.map { |i| [@ca[i]].pack("q<") }.join
    assert_equal expected, got
  end

  def test_duplicate_addrs_get
    # [5, 5, 5] is NOT sequential (deltas != 1), falls to per-cell
    addrs = [5, 5, 5]
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    expected = [@ca[5], @ca[5], @ca[5]].pack("q<*")
    assert_equal expected, got
  end

  # ---- PUT path: round-trip parity ----

  def test_whole_view_sequential_put_round_trip
    src_ca = CArray.int64(N).tap { |i| i[] = 1000 + i }
    addrs = (0...N).to_a
    target = CArray.int64(N) { 0 }
    CArray.bench_xfer_addrs_put_addrs(target, addrs, src_ca.dump_binary)
    assert_equal src_ca.to_a, target.to_a
  end

  def test_subregion_sequential_put_round_trip
    target = CArray.int64(N) { -1 }
    addrs = (10...40).to_a
    payload = addrs.map { |i| i * 100 }.pack("q<*")
    CArray.bench_xfer_addrs_put_addrs(target, addrs, payload)
    # Sub-region overwritten, outside untouched
    (0...N).each do |i|
      if i >= 10 && i < 40
        assert_equal i * 100, target[i]
      else
        assert_equal(-1, target[i])
      end
    end
  end

  def test_random_addrs_put_round_trip
    target = CArray.int64(N) { 0 }
    addrs = [5, 17, 3, 42, 1, 60, 11, 8]
    payload = addrs.map { |a| a + 7000 }.pack("q<*")
    CArray.bench_xfer_addrs_put_addrs(target, addrs, payload)
    addrs.each { |a| assert_equal(a + 7000, target[a]) }
  end

  def test_put_then_get_round_trip_sequential
    addrs = (5...25).to_a
    payload = addrs.map { |a| a * 999 }.pack("q<*")
    CArray.bench_xfer_addrs_put_addrs(@ca, addrs, payload)
    got = CArray.bench_xfer_addrs_get_addrs(@ca, addrs, 1)
    assert_equal payload, got
  end

  # ---- Production hot pattern: ca[:is_not_masked] += v ----

  def test_dominant_true_mask_increment_idempotent
    # When no mask set, ca[:is_not_masked] views all elements via CASelect
    # whose xfer_addrs path internally generates whole-view sequential addrs.
    a = CArray.int64(N).tap { |i| i[] = i }
    expected = a.to_a.map { |v| v + 12 }
    a[:is_not_masked] += 12
    assert_equal expected, a.to_a
  end

  def test_partial_mask_then_select_correctness
    a = CArray.int64(N).tap { |i| i[] = i }
    # mask elements 0..9, then is_not_masked selects 10..N-1
    a[0...10] = UNDEF
    expected = a.to_a
    (10...N).each { |i| expected[i] = a[i] + 100 }
    a[:is_not_masked] += 100
    assert_equal expected, a.to_a
  end

  # ---- Different data_types: ensure no byte-arithmetic regression ----

  def test_sequential_get_data_type_float64
    a = CArray.float64(N).tap { |i| i[] = i * 0.5 + 0.25 }
    addrs = (0...N).to_a
    got = CArray.bench_xfer_addrs_get_addrs(a, addrs, 1)
    assert_equal a.dump_binary, got
  end

  def test_sequential_get_data_type_uint8
    a = CArray.uint8(N).tap { |i| i[] = (i * 3) & 0xff }
    addrs = (0...N).to_a
    got = CArray.bench_xfer_addrs_get_addrs(a, addrs, 1)
    assert_equal a.dump_binary, got
  end

  def test_sequential_get_data_type_int16
    a = CArray.int16(N).tap { |i| i[] = i - 100 }
    addrs = (0...N).to_a
    got = CArray.bench_xfer_addrs_get_addrs(a, addrs, 1)
    assert_equal a.dump_binary, got
  end

end
