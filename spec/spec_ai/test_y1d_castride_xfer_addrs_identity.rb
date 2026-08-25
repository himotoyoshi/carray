# Y.1.d (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CAStride family
# xfer_addrs slot identity-transform fast path.  Triggers for simple
# reshape (= CARefer is_deformed 0/1) when whole-view sequential addrs
# correspond to identity mapping after compose_to_root.
#
# Non-identity views (= transpose, sliced, byte reinterpret) preserved
# via legacy per-cell remap.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY1dCAStrideXferAddrsIdentity < Test::Unit::TestCase

  def setup
    @entity = CArray.int64(200, 200)
    (200 * 200).times { |k| @entity[k / 200, k % 200] = k * 7 + 3 }
  end

  # ---- Identity transform: simple reshape (= CARefer) ----

  def test_simple_reshape_whole_view_get
    flat = @entity.flatten   # CARefer reshape to 1D
    addrs = (0...flat.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(flat, addrs, 1)
    assert_equal flat.to_ca.dump_binary, got
  end

  def test_reshape_to_different_2d_whole_view_get
    rs = @entity.reshape(400, 100)
    addrs = (0...rs.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(rs, addrs, 1)
    assert_equal rs.to_ca.dump_binary, got
  end

  def test_simple_reshape_put_round_trip
    target = @entity.dup
    rs = target.reshape(400, 100)
    payload_ca = CArray.int64(400, 100)
    rs.elements.times { |k| payload_ca[k / 100, k % 100] = -k - 1 }
    addrs = (0...rs.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(rs, addrs, payload_ca.dump_binary)
    assert_equal payload_ca.to_a, rs.to_a
  end

  # ---- Chain: a[idx_2d] (= CAMAPPING_REMOVAL silent forward) ----

  def test_chain_idx_2d_whole_view_get
    # outer reshape -> CAGrid -> inner reshape -> entity
    idx2d = CArray.int32(50, 40)
    (50 * 40).times { |k| idx2d[k / 40, k % 40] = (k * 7) % @entity.elements }
    chain = @entity[idx2d]
    addrs = (0...chain.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(chain, addrs, 1)
    assert_equal chain.to_ca.dump_binary, got
  end

  # ---- Non-identity views: legacy path preserved ----

  def test_transpose_whole_view_uses_legacy_correctness
    # Transpose composed_strides are not row-major -> fast path skipped
    tp = @entity.transpose
    addrs = (0...tp.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(tp, addrs, 1)
    assert_equal tp.to_ca.dump_binary, got
  end

  def test_block_subregion_whole_view_uses_legacy_correctness
    # Sub-region CABlock has non-zero composed_base or non-row-major strides
    blk = @entity[10..50, 20..80]
    addrs = (0...blk.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(blk, addrs, 1)
    assert_equal blk.to_ca.dump_binary, got
  end

  def test_strided_slice_uses_legacy_correctness
    # Strided sub-region: composed_base != 0 -> fast path skipped
    blk = @entity[5..-1, 10..-1]
    addrs = (0...blk.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(blk, addrs, 1)
    assert_equal blk.to_ca.dump_binary, got
  end

  # ---- Random addrs always preserved via legacy path ----

  def test_simple_reshape_random_addrs
    flat = @entity.flatten
    addrs = [13, 99, 4000, 7, 19999, 333]
    got = CArray.bench_xfer_addrs_get_addrs(flat, addrs, 1)
    expected = addrs.map { |a| flat[a] }.pack("q<*")
    assert_equal expected, got
  end

  # ---- Different parent data_types ----

  def test_simple_reshape_float64_parent
    parent = CArray.float64(10, 8)
    10.times { |i| 8.times { |j| parent[i, j] = i * 0.25 + j * 0.0625 } }
    rs = parent.flatten
    addrs = (0...rs.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(rs, addrs, 1)
    assert_equal rs.to_ca.dump_binary, got
  end

  # ---- Partial / sub-region addrs (legacy path) ----

  def test_simple_reshape_subregion_addrs_legacy
    flat = @entity.flatten
    addrs = (100...500).to_a
    got = CArray.bench_xfer_addrs_get_addrs(flat, addrs, 1)
    expected = addrs.map { |a| flat[a] }.pack("q<*")
    assert_equal expected, got
  end
end
