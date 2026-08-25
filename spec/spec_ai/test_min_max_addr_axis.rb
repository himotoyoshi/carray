# ----------------------------------------------------------------------------
#
#  spec_ai/test_min_max_addr_axis.rb
#
#  Tests for *_addr(axis:) family (= companion to *_index(axis:),
#  returns view-flat addresses for direct flatten[addrs] gather).
#  Added as follow-up to PROPOSAL_TAKE_ALONG_AXIS T.6 reflection.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMinMaxAddrAxis < Test::Unit::TestCase

  # ---- 2-D axis 1 -------------------------------------------------------

  def test_max_addr_axis_1_returns_view_flat_addresses
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    addr = a.max_addr(axis: 1)
    # max per row: row 0 -> col 1 (val 5); row 1 -> col 0 (val 9)
    # view-flat addresses (row-major): row 0 col 1 = 1; row 1 col 0 = 3
    assert_equal [1, 3], addr.to_a
    # gather via flatten[addr]
    assert_equal [5.0, 9.0], a.flatten[addr].to_a
  end

  def test_min_addr_axis_1
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    addr = a.min_addr(axis: 1)
    # min per row: row 0 -> col 0 (val 1) = addr 0; row 1 -> col 1 (val 0) = addr 4
    assert_equal [0, 4], addr.to_a
    assert_equal [1.0, 0.0], a.flatten[addr].to_a
  end

  # ---- 2-D axis 0 -------------------------------------------------------

  def test_min_addr_axis_0
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    addr = a.min_addr(axis: 0)
    # min per col: col 0 -> row 0 (val 1) = addr 0
    #              col 1 -> row 1 (val 0) = addr 4
    #              col 2 -> row 0 (val 2) = addr 2
    assert_equal [0, 4, 2], addr.to_a
    assert_equal [1.0, 0.0, 2.0], a.flatten[addr].to_a
  end

  # ---- 3-D --------------------------------------------------------------

  def test_max_addr_3d_axis_2
    a = CArray.float64(2, 3, 4).seq!
    addr = a.max_addr(axis: 2)
    # Each fiber is [4k, 4k+1, 4k+2, 4k+3] - max is at position 3 of fiber
    # view-flat: 3, 7, 11, 15, 19, 23 (= each + 3 within the contiguous block)
    expected = [[3, 7, 11], [15, 19, 23]]
    assert_equal expected, addr.to_a
  end

  # ---- axis nil (legacy flat) -------------------------------------------

  def test_min_addr_axis_nil_returns_flat_scalar
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    # min at row 1 col 1 (val 0) = flat addr 4
    assert_equal 4, a.min_addr
  end

  def test_max_addr_axis_nil_returns_flat_scalar
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    # max at row 1 col 0 (val 9) = flat addr 3
    assert_equal 3, a.max_addr
  end

  # ---- axis OOR ---------------------------------------------------------

  def test_min_addr_axis_out_of_range_raises
    a = CA_FLOAT64([1, 2, 3])
    # mkkernel-backed kernel raises IndexError via
    # rb_ca_parse_reduce_axes_kw; same convention as min_index.
    assert_raise(IndexError) { a.min_addr(axis: 5) }
  end

  def test_max_addr_axis_negative
    a = CA_FLOAT64([[1, 5, 2], [9, 0, 3]])
    assert_equal a.max_addr(axis: 1).to_a, a.max_addr(axis: -1).to_a
  end

  # ---- direct gather idiom ---------------------------------------------

  def test_min_addr_direct_gather_canonical_idiom
    # Canonical pattern enabled by *_addr(axis:):
    #   values_per_fiber = self.flatten[key.min_addr(axis: k)]
    # Cleaner and faster than the *_index + take_along_axis chain.
    a = CA_FLOAT64([[10, 20, 30], [40, 50, 60]])
    key = CA_INT32([[3, 1, 2], [6, 4, 5]])
    # per row: key min at col 1 -> self [20, 50]
    assert_equal [20.0, 50.0], a.flatten[key.min_addr(axis: 1)].to_a
  end

  def test_max_addr_pair_with_min_addr_consistency
    a = CA_FLOAT64([[5, 1, 3], [2, 9, 4]])
    # max per row: row 0 col 0 (5) addr 0; row 1 col 1 (9) addr 4
    # min per row: row 0 col 1 (1) addr 1; row 1 col 0 (2) addr 3
    assert_equal [0, 4], a.max_addr(axis: 1).to_a
    assert_equal [1, 3], a.min_addr(axis: 1).to_a
    assert_equal [5.0, 9.0], a.flatten[a.max_addr(axis: 1)].to_a
    assert_equal [1.0, 2.0], a.flatten[a.min_addr(axis: 1)].to_a
  end

end
