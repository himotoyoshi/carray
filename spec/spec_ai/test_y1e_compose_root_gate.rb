# Y.1.e (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): compose-to-root gate
# extension for Y.1.a/b/c view slots.  Lifts parent->ptr gate through
# identity CAStride compose-fold, so virtual CARefer reshape over entity
# (= a.flatten[idx].reshape(*idx.shape) chain pattern) hits the fast path.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY1eComposeRootGate < Test::Unit::TestCase

  def setup
    @entity = CArray.int64(20, 16)
    20.times { |i| 16.times { |j| @entity[i, j] = i * 100 + j } }
  end

  # ---- Chain pattern: a[idx_2d] (= CAMAPPING_REMOVAL silent forward) ----

  def test_chain_idx_2d_whole_view_get
    idx2d = CArray.int32(8, 5)
    (8 * 5).times { |k| idx2d[k / 5, k % 5] = (k * 7) % @entity.elements }
    chain = @entity[idx2d]
    addrs = (0...chain.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(chain, addrs, 1)
    assert_equal chain.to_ca.dump_binary, got
  end

  def test_chain_idx_2d_get_against_ruby_lookup
    idx2d = CArray.int32(4, 6)
    (4 * 6).times { |k| idx2d[k / 6, k % 6] = (k * 11 + 3) % @entity.elements }
    chain = @entity[idx2d]
    addrs = (0...chain.elements).to_a
    got_bytes = CArray.bench_xfer_addrs_get_addrs(chain, addrs, 1)
    expected = (0...chain.elements).map { |a| chain[a / 6, a % 6] }.pack("q<*")
    assert_equal expected, got_bytes
  end

  # ---- CAGrid over virtual CARefer ----

  def test_cagrid_over_flatten_parent_whole_view
    # CAGrid with parent = a.flatten (virtual CARefer)
    flat = @entity.flatten   # virtual, no ptr
    assert_false flat.attached?
    idx = CArray.int32(10)
    10.times { |k| idx[k] = k * 17 % flat.elements }
    g = flat.grid(idx)
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  # ---- CASelect over virtual CARefer ----

  def test_caselect_over_flatten_parent_whole_view
    flat = @entity.flatten   # virtual
    mask = CArray.boolean(flat.elements)
    flat.elements.times { |k| mask[k] = (k % 3 == 0 ? 1 : 0) }
    sel = flat[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  # ---- CSA over virtual CARefer ----

  def test_csa_over_flatten_then_reshape_whole_view
    # CSA with parent = a 2-D reshape (virtual CARefer over entity)
    reshaped = @entity.reshape(40, 8)   # virtual, identity element-mapping
    mask = CArray.boolean(40)
    40.times { |i| mask[i] = (i % 2 == 0 ? 1 : 0) }
    csa = reshaped[mask, nil]
    addrs = (0...csa.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(csa, addrs, 1)
    assert_equal csa.to_ca.dump_binary, got
  end

  # ---- Non-identity parent: must NOT take fast path (legacy correctness) ----

  def test_cagrid_over_transpose_parent_whole_view
    # Transpose composed_strides not row-major -> resolver returns original cand
    # Y.1.b sees no ptr on transpose parent -> falls to legacy per-cell remap
    tp = @entity.transpose
    idx = CArray.int32(5)
    5.times { |k| idx[k] = k * 3 }
    g = tp.grid(idx, nil)
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  def test_caselect_over_cafake_parent_whole_view
    # CAFake is not CAStride family -> resolver returns original cand
    # parent has no ptr -> falls to legacy path
    fake = @entity.fake(:float64)
    mask = CArray.boolean(fake.elements) { 1 }   # all true
    sel = fake[mask]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  # ---- PUT round-trip through chain ----

  def test_chain_put_round_trip
    target = @entity.dup
    idx2d = CArray.int32(4, 5)
    # use disjoint indices to avoid scatter conflicts
    [3, 17, 41, 88, 102, 7, 19, 33, 200, 150, 99, 5, 222, 60, 280, 1, 313, 90, 11, 14].each_with_index do |v, k|
      idx2d[k / 5, k % 5] = v
    end
    chain = target[idx2d]
    payload = CArray.int64(4, 5)
    (4 * 5).times { |k| payload[k / 5, k % 5] = -k - 100 }
    addrs = (0...chain.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(chain, addrs, payload.dump_binary)
    # After scatter, the indexed positions in target should hold payload values
    20.times { |k| assert_equal payload[k / 5, k % 5], target.flatten[idx2d[k / 5, k % 5]] }
  end

  # ---- Multi-data_type ----

  def test_chain_float64_parent
    parent = CArray.float64(20, 16)
    20.times { |i| 16.times { |j| parent[i, j] = i * 0.5 + j * 0.125 } }
    idx2d = CArray.int32(6, 4)
    (6 * 4).times { |k| idx2d[k / 4, k % 4] = (k * 13) % parent.elements }
    chain = parent[idx2d]
    addrs = (0...chain.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(chain, addrs, 1)
    assert_equal chain.to_ca.dump_binary, got
  end
end
