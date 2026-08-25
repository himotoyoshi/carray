# Source-address surface fill-in for the iterator family:
#   - CABlockIterator#min_addr / #max_addr / #sort_addr
#   - CAWindowIterator#min_addr / #max_addr (with the boundary policy)
#   - CAGroupIterator#min_index / #max_index reasoned NotImplementedError
# Each _addr result is checked by round-tripping it back into the raveled source.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestIteratorSourceAddr < Test::Unit::TestCase

  # ---- CABlockIterator ------------------------------------------------------

  def test_block_min_max_addr_roundtrip
    src = CA_DOUBLE([[5, 2, 8], [9, 3, 7], [4, 6, 1]])   # 3x3, ragged under 2x2
    bi  = src.blocks(2, 2)
    sf  = src.reshape(src.elements)
    assert_equal [2, 2], bi.min_addr.shape
    assert_equal bi.min.reshape(4).to_a, sf[bi.min_addr.reshape(4)].to_a
    assert_equal bi.max.reshape(4).to_a, sf[bi.max_addr.reshape(4)].to_a
  end

  def test_block_addr_masked_tile
    src = CA_DOUBLE([[5, 2, 8], [9, 3, 7], [4, 6, 1]])
    src[2, 2] = UNDEF                                    # the 1x1 corner tile is all-masked
    bi = src.blocks(2, 2)
    assert_equal true, bi.min_addr.is_masked[1, 1]         # empty tile -> masked address
    assert_equal false, bi.min_addr.is_masked[0, 0]
  end

  def test_block_sort_addr_source_shaped
    src = CA_DOUBLE([[5, 2, 8], [9, 3, 7], [4, 6, 1]])
    bi  = src.blocks(2, 2)
    sa  = bi.sort_addr
    assert_equal src.shape, sa.shape                    # source-shaped
    sf  = src.reshape(src.elements)
    # reading a tile's cells row-major gives its source addresses in ascending value
    vals = [sa[0, 0], sa[0, 1], sa[1, 0], sa[1, 1]].map { |a| sf[a] }
    assert_equal vals.sort, vals
  end

  # ---- CAWindowIterator -----------------------------------------------------

  def test_window_min_max_addr_nearest
    a = CA_DOUBLE([5, 2, 8, 1, 9])
    w = a.windows(-1..1, bounds: :nearest)
    af = a.reshape(5)
    assert_equal a.shape, w.min_addr.shape
    assert_equal w.min.to_a, af[w.min_addr.reshape(5)].to_a
    assert_equal w.max.to_a, af[w.max_addr.reshape(5)].to_a
  end

  def test_window_min_addr_truncate_and_2d
    a = CA_DOUBLE([5, 2, 8, 1, 9])
    wt = a.windows(-1..1, bounds: :truncate)            # valid mode, shrunk output
    assert_equal [3], wt.min_addr.shape
    assert_equal wt.min.to_a, a.reshape(5)[wt.min_addr.reshape(3)].to_a
    a2 = CA_DOUBLE([[5, 2, 8], [1, 9, 3]])
    w2 = a2.windows(-1..1, -1..1, bounds: :nearest)
    assert_equal a2.shape, w2.min_addr.shape
    assert_equal w2.min.reshape(6).to_a, a2.reshape(6)[w2.min_addr.reshape(6)].to_a
  end

  def test_window_constant_margin_winner_is_masked
    a = CA_DOUBLE([5, 2, 8, 1, 9])
    # a very small constant margin becomes the window minimum at the edges, and a
    # padded margin cell has no source address -> that result is masked.
    w = a.windows(-1..1, bounds: :constant, fill_value: -100.0)
    ma = w.min_addr
    assert_equal true, ma.is_masked[0]                     # edge window min is the margin
    assert_equal true, ma.is_masked[4]
    assert_equal false, ma.is_masked[2]                     # interior min is a real cell
    assert_equal a.reshape(5)[ma[2]], w.min[2]
  end

  # ---- CAGroupIterator ------------------------------------------------------

  def test_group_min_index_raises_with_reason
    g = CArray.float64(6).seq![CA_INT32([0, 1, 0, 1, 0, 1]).categorize]
    err = assert_raise(NotImplementedError) { g.min_index(axis: :group) }
    assert_match(/min_addr/, err.message)               # guides to the address form
    assert_raise(NotImplementedError) { g.max_index(axis: :group) }
    # the address form is available
    assert_kind_of CArray, g.min_addr(axis: :group)
  end
end
