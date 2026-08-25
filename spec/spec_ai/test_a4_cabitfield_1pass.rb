# A.4 (PROPOSAL_CABITARRAY_REDESIGN.md §4.A.4):
# CABitfield xfer_addrs whole-view 1-pass RMW path.  Skip the 2-pass
# scratch + ca_xfer_addrs(GET)+RMW+ca_xfer_addrs(PUT) by driving
# bitfield_fetch/bitfield_store directly against parent.ptr.
#
# Hygiene work (= noise reduction), not hot-path optimization.  Test
# focus: byte parity preservation + RMW correctness (= non-field bits
# preserved, only field bits overwritten).

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestA4CABitfield1Pass < Test::Unit::TestCase

  # ---- whole-view GET byte parity ----

  def test_whole_view_get_byte_parity_with_to_ca
    parent = CArray.uint32(20).tap { |x| x[] = x.seq * 0x01020304 + 0x10000001 }
    bf = parent.bitfield(0..7)   # extract low 8 bits as uint8 view
    addrs = (0...bf.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(bf, addrs, 1)
    assert_equal bf.to_ca.dump_binary, got
  end

  def test_whole_view_get_mid_bit_range
    parent = CArray.uint32(8).tap { |a| a[] = [0xDEADBEEF, 0x12345678, 0xFFFFFFFF, 0x00000000,
                                                0xAAAAAAAA, 0x55555555, 0x0F0F0F0F, 0xF0F0F0F0] }
    bf = parent.bitfield(8..15)   # second byte
    addrs = (0...bf.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(bf, addrs, 1)
    assert_equal bf.to_ca.dump_binary, got
  end

  # ---- whole-view PUT round-trip preserves non-field bits ----

  def test_whole_view_put_preserves_nonfield_bits
    parent = CArray.uint32(8) { 0xDEADBEEF }   # all 0xDEADBEEF initially
    bf = parent.bitfield(0..7)                  # field = low 8 bits
    addrs = (0...bf.elements).to_a

    # Write new low-8-bit values
    payload = ([0x42] * 8).pack("C*")
    CArray.bench_xfer_addrs_put_addrs(bf, addrs, payload)

    # Verify: low byte = 0x42, upper 24 bits preserved = 0xDEADBE
    8.times { |i| assert_equal 0xDEADBE42, parent[i], "cell #{i}" }
  end

  def test_whole_view_put_mid_bit_range_preserves
    parent = CArray.uint32(4).tap { |__a| __a[] = [0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000] }
    bf = parent.bitfield(8..15)                # second byte (bits 8..15)
    addrs = (0...bf.elements).to_a
    payload = [0xAA, 0xBB, 0xCC, 0xDD].pack("C*")
    CArray.bench_xfer_addrs_put_addrs(bf, addrs, payload)
    # Original 0xFFFFFFFF -> bits 8..15 = 0xAA -> 0xFFFFAAFF
    assert_equal 0xFFFFAAFF, parent[0]
    assert_equal 0xFFFFBBFF, parent[1]
    # Original 0x00000000 -> bits 8..15 = 0xCC -> 0x0000CC00
    assert_equal 0x0000CC00, parent[2]
    assert_equal 0x0000DD00, parent[3]
  end

  def test_whole_view_put_zero_overwrites_field_only
    parent = CArray.uint32(4) { 0xFFFFFFFF }
    bf = parent.bitfield(0..7)
    addrs = (0...bf.elements).to_a
    payload = ([0x00] * 4).pack("C*")
    CArray.bench_xfer_addrs_put_addrs(bf, addrs, payload)
    # Low byte zeroed, upper preserved
    4.times { assert_equal 0xFFFFFF00, parent[_1] }
  end

  # ---- Arbitrary addrs (legacy 2-pass path) ----

  def test_arbitrary_addrs_get_legacy_correctness
    parent = CArray.uint32(20).tap { |x| x[] = x.seq * 0x01020304 + 0x10000001 }
    bf = parent.bitfield(0..7)
    addrs = [3, 17, 0, 11, 5]
    got = CArray.bench_xfer_addrs_get_addrs(bf, addrs, 1)
    expected = addrs.map { |a| parent[a] & 0xFF }.pack("C*")
    assert_equal expected, got
  end

  def test_arbitrary_addrs_put_legacy_correctness
    parent = CArray.uint32(8) { 0xAAAA0000 }
    bf = parent.bitfield(0..7)
    # Write to scattered cells, not whole-view
    addrs = [1, 3, 5]
    payload = [0xCC, 0xDD, 0xEE].pack("C*")
    CArray.bench_xfer_addrs_put_addrs(bf, addrs, payload)
    # Only cells 1, 3, 5 modified; others stay 0xAAAA0000
    assert_equal 0xAAAA0000, parent[0]
    assert_equal 0xAAAA00CC, parent[1]
    assert_equal 0xAAAA0000, parent[2]
    assert_equal 0xAAAA00DD, parent[3]
    assert_equal 0xAAAA0000, parent[4]
    assert_equal 0xAAAA00EE, parent[5]
  end

  def test_empty_addrs
    parent = CArray.uint32(8)
    bf = parent.bitfield(0..7)
    got = CArray.bench_xfer_addrs_get_addrs(bf, [], 1)
    assert_equal "", got
  end

  # ---- Virtual parent (Y.1.e cascade) ----

  def test_whole_view_get_over_flatten_parent
    parent2d = CArray.uint32(4, 5)
    4.times { |i| 5.times { |j| parent2d[i, j] = i * 100 + j } }
    flat = parent2d.flatten   # virtual CARefer
    bf = flat.bitfield(0..7)
    addrs = (0...bf.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(bf, addrs, 1)
    assert_equal bf.to_ca.dump_binary, got
  end

  # ---- Cross-path consistency ----

  def test_all_paths_byte_identical_get
    parent = CArray.uint32(50).tap { |x| x[] = x.seq * 17 + 3 }
    bf = parent.bitfield(0..7)
    bytes_all  = CArray.bench_xfer_all_get(bf, 1)
    bytes_str  = CArray.bench_xfer_stride_get(bf, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(bf, 1)
    assert_equal bytes_all, bytes_str
    assert_equal bytes_all, bytes_addr
    assert_equal bf.to_ca.dump_binary, bytes_all
  end

  # ---- Different parent data_types / field widths ----

  def test_uint8_parent_whole_view_get
    parent = CArray.uint8(16).tap { |x| x[] = x.seq * 7 }
    bf = parent.bitfield(0..3)   # 4-bit field
    addrs = (0...bf.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(bf, addrs, 1)
    assert_equal bf.to_ca.dump_binary, got
  end

  def test_uint16_parent_whole_view_put_preserves
    parent = CArray.uint16(8) { 0xFF00 }
    bf = parent.bitfield(0..7)
    addrs = (0...bf.elements).to_a
    payload = ([0x99] * 8).pack("C*")
    CArray.bench_xfer_addrs_put_addrs(bf, addrs, payload)
    8.times { assert_equal 0xFF99, parent[_1] }
  end
end
