# A.3.1 / A.3.2 (PROPOSAL_CABITARRAY_REDESIGN.md §4):
# CABitarray xfer_addrs / xfer_stride whole-view fast path.
# Bulk bit-unpack/pack primitive replaces per-cell remap loop.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestACABitarrayBulkPath < Test::Unit::TestCase

  # ---- xfer_addrs whole-view GET (= A.3.1) ----

  def test_xfer_addrs_whole_view_byte_parity_with_to_ca
    parent = CArray.uint8(40)
    40.times { |i| parent[i] = (i * 7) & 0xff }
    v = parent.bitarray
    addrs = (0...v.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    assert_equal v.to_ca.dump_binary, got
  end

  def test_xfer_addrs_whole_view_against_per_cell
    parent = CArray.uint8(8).tap { |__a| __a[] = [0xAA, 0x55, 0xFF, 0x00, 0x0F, 0xF0, 0x33, 0xCC] }
    v = parent.bitarray
    addrs = (0...v.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    # Manual: LSB-first bit extraction per byte
    expected = parent.to_a.map { |b| 8.times.map { |i| (b >> i) & 1 } }.flatten.pack("c*")
    assert_equal expected, got
  end

  def test_xfer_addrs_partial_addrs_legacy_path_correctness
    parent = CArray.uint8(8).tap { |__a| __a[] = [0xAA, 0x55, 0xFF, 0x00, 0x0F, 0xF0, 0x33, 0xCC] }
    v = parent.bitarray
    # Pick scattered addrs that DON'T cover whole-view sequentially
    addrs = [0, 5, 10, 15, 20, 25, 30, 35]
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    expected = addrs.map { |a| (parent[a / 8] >> (a % 8)) & 1 }.pack("c*")
    assert_equal expected, got
  end

  def test_xfer_addrs_random_addrs_legacy_correctness
    parent = CArray.uint8(16)
    16.times { |i| parent[i] = (i * 13 + 7) & 0xff }
    v = parent.bitarray
    addrs = [37, 5, 99, 2, 60, 11, 0, 127]
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    expected = addrs.map { |a| (parent[a / 8] >> (a % 8)) & 1 }.pack("c*")
    assert_equal expected, got
  end

  # ---- xfer_addrs whole-view PUT (= A.3.1 PUT-3) ----

  def test_xfer_addrs_whole_view_put_round_trip
    parent = CArray.uint8(8) { 0 }
    v = parent.bitarray
    # payload: alternating 1010 1010 ... pattern
    payload = (0...v.elements).map { |i| i.odd? ? 1 : 0 }.pack("c*")
    addrs = (0...v.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(v, addrs, payload)
    # Each parent byte gets bits LSB-first: bit_i = (byte >> i) & 1
    # Pattern 1010 1010 -> each byte = 0xAA = 170
    8.times { |i| assert_equal 0xAA, parent[i], "byte #{i}" }
  end

  def test_xfer_addrs_whole_view_put_zero_bytes
    parent = CArray.uint8(16) { 0xFF }
    v = parent.bitarray
    payload = ([0] * v.elements).pack("c*")
    addrs = (0...v.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(v, addrs, payload)
    16.times { |i| assert_equal 0, parent[i], "byte #{i}" }
  end

  # ---- xfer_stride whole-view (= A.3.2) ----

  def test_xfer_stride_whole_view_byte_parity_with_xfer_all
    parent = CArray.uint8(50).tap { |x| x[] = x.seq * 3 + 1 }
    v = parent.bitarray
    bytes_all  = CArray.bench_xfer_all_get(v, 1)
    bytes_str  = CArray.bench_xfer_stride_get(v, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(v, 1)
    assert_equal bytes_all, bytes_str
    assert_equal bytes_all, bytes_addr
  end

  # ---- Multi-byte parent (= endian relevant) ----

  def test_uint32_parent_whole_view_get
    parent = CArray.uint32(10).tap { |x| x[] = x.seq * 0x01020304 + 0x10000000 }
    v = parent.bitarray
    addrs = (0...v.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    assert_equal v.to_ca.dump_binary, got
  end

  def test_uint16_parent_whole_view_get
    parent = CArray.uint16(20).tap { |x| x[] = x.seq * 0x0F0F + 1 }
    v = parent.bitarray
    addrs = (0...v.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    assert_equal v.to_ca.dump_binary, got
  end

  # ---- Virtual parent (Y.1.e compose-fold cascade) ----

  def test_bitarray_over_flatten_parent_whole_view
    parent = CArray.uint8(8, 5)
    8.times { |i| 5.times { |j| parent[i, j] = (i * 5 + j) & 0xff } }
    flat = parent.flatten   # virtual CARefer
    v = flat.bitarray
    addrs = (0...v.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(v, addrs, 1)
    assert_equal v.to_ca.dump_binary, got
  end

  # ---- Mask path regression preservation (= §5.C / §6.4) ----

  def test_bitarray_with_masked_parent_preserves_mask_semantics
    parent = CArray.uint8(8) { 0xFF }
    parent[3] = UNDEF
    v = parent.bitarray
    # to_ca via masked path should match xfer_all and xfer_addrs whole-view
    bytes_all  = CArray.bench_xfer_all_get(v, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(v, 1)
    assert_equal bytes_all, bytes_addr
  end

  # ---- Cross-path consistency: xfer_all == xfer_stride == xfer_addrs ----

  def test_all_paths_byte_identical
    parent = CArray.uint8(100).tap { |x| x[] = x.seq * 7 + 13 }
    v = parent.bitarray
    bytes_all  = CArray.bench_xfer_all_get(v, 1)
    bytes_str  = CArray.bench_xfer_stride_get(v, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(v, 1)
    assert_equal bytes_all, bytes_str, "xfer_all != xfer_stride"
    assert_equal bytes_all, bytes_addr, "xfer_all != xfer_addrs"
    assert_equal v.to_ca.dump_binary, bytes_all
  end

  # ---- Empty / degenerate cases ----

  def test_empty_addrs
    parent = CArray.uint8(8) { 0 }
    v = parent.bitarray
    got = CArray.bench_xfer_addrs_get_addrs(v, [], 1)
    assert_equal "", got
  end
end
