# Y.1.b (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CAGrid xfer_addrs
# slot opportunistic axis_dispatch fast path.  Pins byte parity for
# whole-view (production hot) and arbitrary addrs (legacy path).

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY1bCAGridXferAddrs < Test::Unit::TestCase

  def setup
    @parent = CArray.int64(10, 8)
    10.times { |i| 8.times { |j| @parent[i, j] = i * 100 + j } }
  end

  # ---- mask axis variant: a[nil, mask] ----

  def test_grid_mask_axis_whole_view_get
    mask = CArray.boolean(8)
    8.times { |j| mask[j] = (j % 2 == 0 ? 1 : 0) }
    g = @parent[nil, mask]
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  def test_grid_mask_axis_whole_view_put_round_trip
    mask = CArray.boolean(8)
    8.times { |j| mask[j] = (j % 2 == 0 ? 1 : 0) }
    parent = @parent.dup
    g = parent[nil, mask]
    payload = CArray.int64(g.dim[0], g.dim[1])
    g.dim[0].times { |i| g.dim[1].times { |j| payload[i, j] = 9000 + i * 10 + j } }
    addrs = (0...g.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(g, addrs, payload.dump_binary)
    assert_equal payload.to_a, g.to_a
  end

  # ---- idx axis variant: a.grid(idx, nil) ----

  def test_grid_idx_axis_whole_view_get
    idx = CArray.int64(4)
    [3, 0, 7, 2].each_with_index { |v, k| idx[k] = v }
    g = @parent.grid(idx, nil)
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  def test_grid_idx_axis_duplicate_indices_last_write_wins
    # R5 spec preserved: duplicate INDEX entries -> scatter last-write-wins
    parent = @parent.dup
    idx = CArray.int64(3)
    idx[0] = 2; idx[1] = 5; idx[2] = 2   # duplicate row index 2
    g = parent.grid(idx, nil)
    payload = CArray.int64(3, 8)
    3.times { |i| 8.times { |j| payload[i, j] = -i * 10 - j } }
    addrs = (0...g.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(g, addrs, payload.dump_binary)
    # Row 2 of parent receives writes from payload[0] then payload[2] (last wins)
    8.times { |j| assert_equal(-2 * 10 - j, parent[2, j]) }
    8.times { |j| assert_equal(-1 * 10 - j, parent[5, j]) }
  end

  # ---- arbitrary addrs (legacy path correctness) ----

  def test_grid_random_addrs_correctness
    mask = CArray.boolean(8)
    8.times { |j| mask[j] = (j % 2 == 0 ? 1 : 0) }
    g = @parent[nil, mask]   # 10 x 4
    addrs = [37, 5, 19, 2, 28, 11, 0, 39]
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    expected = addrs.map { |a| g[a / 4, a % 4] }.pack("q<*")
    assert_equal expected, got
  end

  def test_grid_empty_addrs
    mask = CArray.boolean(8) { 1 }
    g = @parent[nil, mask]
    got = CArray.bench_xfer_addrs_get_addrs(g, [], 1)
    assert_equal "", got
  end

  # ---- Virtual parent fall-back ----

  def test_grid_with_cafake_parent_falls_through_legacy
    parent_fake = @parent.fake(:float64)
    mask = CArray.boolean(8)
    8.times { |j| mask[j] = (j % 2 == 0 ? 1 : 0) }
    g = parent_fake[nil, mask]
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  # ---- Range axis (= STRIDE kind, post-C1 rebuild) ----

  def test_grid_range_axis_whole_view_get
    # Range axes emit STRIDE descriptor (post C1 CAGrid rebuild)
    g = @parent[nil, 1..4]
    addrs = (0...g.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(g, addrs, 1)
    assert_equal g.to_ca.dump_binary, got
  end

  # ---- chain a[idx_2d] observation: still goes through CASelect, not CAGrid ----

  def test_chain_idx_2d_correctness
    # a[2d_int_array] goes through reshape->CAGrid->reshape->entity chain.
    # Y.1.b CAGrid fast path triggers on the inner CAGrid layer.
    idx_2d = CArray.int64(2, 3)
    [[5, 10, 20], [3, 0, 15]].each_with_index do |row, i|
      row.each_with_index { |v, j| idx_2d[i, j] = v }
    end
    got = @parent.flatten[idx_2d.flatten].reshape(2, 3).to_a
    expected = [[5, 10, 20], [3, 0, 15]].map { |row| row.map { |a| @parent.flatten[a] } }
    assert_equal expected, got
  end
end
