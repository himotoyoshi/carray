# ----------------------------------------------------------------------------
#
#  spec_ai/test_rank_index.rb
#
#  Tests for the mkkernel rank_index kernel (= sort form algorithm: :rank,
#  mask_self: :skip) and the simplified CArray#order built on top.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestRankIndex < Test::Unit::TestCase

  # ---- 1-D rank_index (axis: 0 only) ------------------------------------

  def test_rank_index_1d
    a = CA_FLOAT64([30, 10, 20])
    assert_equal [2, 0, 1], a.rank_index(axis: 0).to_a
  end

  def test_rank_index_1d_with_ties_stable
    # Stable: tied values keep original fiber-local order.
    a = CA_FLOAT64([10, 20, 10, 20])
    # Sorted ascending: 10@0, 10@2, 20@1, 20@3
    # Ranks: a[0]=10 -> 0; a[1]=20 -> 2; a[2]=10 -> 1; a[3]=20 -> 3
    assert_equal [0, 2, 1, 3], a.rank_index(axis: 0).to_a
  end

  # ---- 2-D rank_index (axis: k) -----------------------------------------

  def test_rank_index_2d_axis_1
    b = CA_FLOAT64([[30, 10, 20], [5, 15, 25]])
    assert_equal [[2, 0, 1], [0, 1, 2]], b.rank_index(axis: 1).to_a
  end

  def test_rank_index_2d_axis_0
    b = CA_FLOAT64([[30, 10, 20], [5, 15, 25]])
    # Per column: col 0: 30>5 -> ranks [1, 0]; col 1: 10<15 -> [0, 1]; col 2: 20<25 -> [0, 1]
    assert_equal [[1, 0, 0], [0, 1, 1]], b.rank_index(axis: 0).to_a
  end

  def test_rank_index_axis_negative
    b = CA_FLOAT64([[30, 10, 20], [5, 15, 25]])
    assert_equal b.rank_index(axis: 1).to_a, b.rank_index(axis: -1).to_a
  end

  # ---- mask_skip handling ----------------------------------------------

  def test_rank_index_masked_1d
    c = CA_FLOAT64([30, 10, 20, 40])
    c[1] = UNDEF
    # Unmasked at [0,2,3] = [30,20,40]
    # Sorted: 20@2, 30@0, 40@3
    # Ranks: pos 0 -> 1, pos 2 -> 0, pos 3 -> 2; pos 1 (masked) -> UNDEF
    r = c.rank_index(axis: 0)
    assert_equal [1, 0, 2], r.value[CA_INT([0,2,3])].to_a
    assert_equal [false, true, false, false], r.is_masked.to_a
  end

  def test_rank_index_masked_2d_per_row
    d = CA_FLOAT64([[30,10,20,40],[5,15,25,35]])
    d[0,1] = UNDEF
    d[1,2] = UNDEF
    r = d.rank_index(axis: 1)
    # Row 0 unmasked [30, 20, 40] -> ranks [1, _, 0, 2]
    # Row 1 unmasked [5, 15, 35]  -> ranks [0, 1, _, 2]
    expected_vals = [[1, 0, 0, 2], [0, 1, 0, 2]]
    expected_mask = [[false, true, false, false], [false, false, true, false]]
    assert_equal expected_vals, r.value.to_a
    assert_equal expected_mask, r.is_masked.to_a
  end

  def test_rank_index_no_mask_unchanged_behavior
    # Without mask: behaves like double sort_index (identity).
    a = CA_FLOAT64([3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0])
    expected = a.sort_index_ki(0).sort_index_ki(0).to_a
    assert_equal expected, a.rank_index(axis: 0).to_a
  end

  # ---- order (Ruby surface using rank_index) --------------------------

  def test_order_default_axis_nil
    a = CA_FLOAT64([30, 10, 20])
    assert_equal [2, 0, 1], a.order.to_a
  end

  def test_order_descending
    a = CA_FLOAT64([30, 10, 20])
    assert_equal [0, 2, 1], a.order(descending: true).to_a
  end

  def test_order_axis_1
    b = CA_FLOAT64([[30, 10, 20], [5, 15, 25]])
    assert_equal [[2, 0, 1], [0, 1, 2]], b.order(axis: 1).to_a
  end

  def test_order_2d_axis_nil_flat_ranks
    # axis: nil ranks across the full flattened array, then reshapes.
    b = CA_FLOAT64([[30, 10], [20, 5]])
    # Flat: [30, 10, 20, 5] -> ranks [3, 1, 2, 0]
    assert_equal [[3, 1], [2, 0]], b.order.to_a
  end

  def test_order_masked_axis_nil
    c = CA_FLOAT64([30, 10, 20, 40])
    c[1] = UNDEF
    r = c.order
    assert_equal [1, 0, 2], r.value[CA_INT([0,2,3])].to_a
    assert_equal [false, true, false, false], r.is_masked.to_a
  end

  def test_order_masked_descending
    c = CA_FLOAT64([30, 10, 20, 40])
    c[1] = UNDEF
    # Unmasked: [30, 20, 40], ranks asc [1, 0, 2]
    # Desc: count_not_masked = 3, (3-1) - asc = [1, 2, 0]
    r = c.order(descending: true)
    assert_equal [1, 2, 0], r.value[CA_INT([0,2,3])].to_a
  end

  # ---- regression: 2-D / 3-D + axis + mask + descending broadcast ------

  def test_order_2d_axis_masked_descending_broadcast
    # Bug: count_not_masked(axis: k) returns CArray of shape
    # self.shape - axis k; the descending broadcast `(n - 1) - asc`
    # needed a length-1 axis re-inserted at axis k for shape parity.
    b = CA_FLOAT64([[30, 10, 20, 40], [5, 15, 25, 35]])
    b[0, 1] = UNDEF
    b[1, 2] = UNDEF
    desc = b.order(axis: 1, descending: true)
    # Row 0 unmasked 3 cells, asc ranks [1, _, 0, 2], desc = [1, _, 2, 0]
    # Row 1 unmasked 3 cells, asc ranks [0, 1, _, 2], desc = [2, 1, _, 0]
    assert_equal [[1, 0, 2, 0], [2, 1, 0, 0]], desc.value.to_a
    assert_equal [[false, true, false, false], [false, false, true, false]], desc.is_masked.to_a
  end

  def test_order_3d_axis_middle_masked_descending
    c = CArray.float64(2, 3, 4).seq!
    c[0, 1, 2] = UNDEF
    asc  = c.order(axis: 1)
    desc = c.order(axis: 1, descending: true)
    # desc[i, j, k] + asc[i, j, k] == count_not_masked(axis: 1)[i, k] - 1
    # at unmasked positions
    n = c.count_not_masked(axis: 1)
    2.times do |i|
      3.times do |j|
        4.times do |k|
          next if c[i, j, k] == UNDEF
          assert_equal n[i, k] - 1 - asc[i, j, k], desc[i, j, k],
                       "i=#{i}, j=#{j}, k=#{k}"
        end
      end
    end
  end

  # ---- method: :dense -----------------------------------------------------
  #
  # :ordinal (default) always assigns a distinct rank (ties broken by
  # position); :dense assigns tied values the same rank.  Motivating use
  # case: order(descending: true, method: :dense) as a sort_addr priority
  # key -- ordinal ranks are already a total order, so a lower-priority
  # sort_addr key is never consulted on ties; dense ranks preserve the
  # tie so it is.

  def test_rank_index_dense_all_tied
    a = CA_INT32([10, 10, 10])
    assert_equal [0, 1, 2], a.rank_index.to_a
    assert_equal [0, 0, 0], a.rank_index(method: :dense).to_a
  end

  def test_rank_index_dense_with_gaps
    a = CA_INT32([5, 4, 3, 4, 2])
    # distinct ascending: 2 -> 0, 3 -> 1, 4 -> 2 (tied @1,3), 5 -> 3
    assert_equal [3, 2, 1, 2, 0], a.rank_index(method: :dense).to_a
  end

  def test_rank_index_dense_axis
    a = CArray.int32(2, 4) { |i| [10, 10, 5, 5, 1, 2, 1, 2][i] }
    assert_equal [[0, 0, 0, 0], [0, 0, 0, 0]], a.rank_index(axis: 1, method: :dense).to_a
  end

  def test_rank_index_dense_masked
    a = CA_INT32([5, 4, 3, 4, 2])
    a[1] = UNDEF                                # [5, UNDEF, 3, 4, 2]
    # unmasked ascending distinct: 2 -> 0, 3 -> 1, 4 -> 2, 5 -> 3
    assert_equal [3, UNDEF, 1, 2, 0], a.rank_index(method: :dense).to_a
  end

  def test_rank_index_dense_object_and_fixlen
    o = CA_OBJECT([3, 1, 3, 1, 2])
    assert_equal [2, 0, 2, 0, 1], o.rank_index(method: :dense).to_a

    g = CA_FIXLEN(%w[cat ant cat bee], bytes: 3)
    assert_equal [2, 0, 2, 1], g.rank_index(method: :dense).to_a
  end

  def test_rank_index_unknown_method_raises
    a = CA_INT32([1, 2, 3])
    assert_raise(ArgumentError) { a.rank_index(method: :bogus) }
  end

  def test_order_dense_default_is_ordinal
    a = CA_INT32([10, 10, 10])
    assert_equal a.rank_index.to_a, a.order.to_a
  end

  def test_order_dense_matches_rank_index
    a = CA_INT32([5, 4, 3, 4, 2])
    assert_equal a.rank_index(method: :dense).to_a, a.order(method: :dense).to_a
  end

  def test_order_dense_descending_ties_preserved
    # Values tied under a[0..1] (both 5); descending dense rank must keep
    # them equal so a downstream sort_addr key still resolves the tie.
    a = CA_INT32([5, 5])
    b = CA_INT32([1, 2])
    addr = CArray.sort_addr(a.order(descending: true, method: :dense), b)
    assert_equal [1, 2], b[addr].to_a

    # Contrast: :ordinal (default) never ties, so the b key is ignored.
    addr_ordinal = CArray.sort_addr(a.order(descending: true), b)
    assert_equal [2, 1], b[addr_ordinal].to_a
  end

  def test_order_dense_descending_group_order_and_ties
    a = CA_INT32([5, 4, 3, 4, 2])
    desc_dense = a.order(descending: true, method: :dense)
    # Ties (index 1 and 3, both value 4) still share one rank.
    assert_equal desc_dense[1], desc_dense[3]
    # Overall group order still runs 5 > 4 > 3 > 2 (ranks ascending 0..).
    values_by_rank = desc_dense.to_a.zip(a.to_a).sort_by(&:first).map(&:last)
    assert_equal [5, 4, 4, 3, 2], values_by_rank
  end

  def test_order_dense_unknown_method_raises
    a = CA_INT32([1, 2, 3])
    assert_raise(ArgumentError) { a.order(method: :bogus) }
  end

end
