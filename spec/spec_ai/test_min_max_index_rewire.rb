# spec_ai/test_min_max_index_rewire.rb
#
# Rewire of CArray#min_addr / CArray#max_addr (retired in E.7 stat_proc
# retire, commit f5c7ecd) to mkkernel argmin_ki / argmax_ki, exposed
# under the *_index naming convention per CLAUDE.md「設計の前提: 位置を
# 返す method は *_index」.
#
# 3.0 breaking: name changed from min_addr / max_addr to min_index /
# max_index.  Later revision (PROPOSAL_TAKE_ALONG_AXIS follow-up,
# 2026-06-08): min_addr / max_addr re-introduced with NEW axis-aware
# semantics as siblings of sort_addr(axis:) (= return view-flat
# addresses suitable for direct flatten[addrs] gather).  The axis-nil
# behavior of min_addr / max_addr delegates to min_index / max_index
# (same flat Integer scalar return), so the rename is preserved at the
# axis-nil level.
#
# NEW capability: per-axis support (= `a.min_index(axis: 0)` returns column-
# wise row-of-min indices, same shape as other Phase E reductions).

require "test/unit"
require "carray"

class TestMinMaxIndexRewire < Test::Unit::TestCase
  # --- flatten (legacy parity, sans the *_addr name change) ---

  def test_min_index_flat_float
    a = CArray.float64(6)
    a[] = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0]
    assert_equal 1, a.min_index  # first minimum
    assert_kind_of Integer, a.min_index
  end

  def test_max_index_flat_float
    a = CArray.float64(6)
    a[] = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0]
    assert_equal 5, a.max_index
  end

  def test_min_max_index_flat_int
    c = CArray.int32(5)
    c[] = [10, -5, 3, -5, 7]
    assert_equal 1, c.min_index
    assert_equal 0, c.max_index
  end

  # --- per-axis (NEW capability) ---

  def test_min_index_per_axis_2d
    b = CArray.float64(3, 4)
    b[] = [[3, 1, 4, 1], [5, 9, 2, 6], [5, 3, 5, 8]]
    r0 = b.min_index(axis: 0)  # column-wise row of min
    r1 = b.min_index(axis: 1)  # row-wise col of min
    assert_equal [0, 0, 1, 0], r0.to_a
    assert_equal [1, 2, 1], r1.to_a
    assert_equal CA_INT64, r0.data_type
    assert_equal CA_INT64, r1.data_type
  end

  def test_max_index_per_axis_2d
    b = CArray.float64(3, 4)
    b[] = [[3, 1, 4, 1], [5, 9, 2, 6], [5, 3, 5, 8]]
    r0 = b.max_index(axis: 0)
    r1 = b.max_index(axis: 1)
    # col 0: [3,5,5] -> first max at row 1 (tie broken by lowest idx)
    # col 1: [1,9,3] -> row 1
    # col 2: [4,2,5] -> row 2
    # col 3: [1,6,8] -> row 2
    assert_equal [1, 1, 2, 2], r0.to_a
    # row 0: [3,1,4,1] -> col 2
    # row 1: [5,9,2,6] -> col 1
    # row 2: [5,3,5,8] -> col 3
    assert_equal [2, 1, 3], r1.to_a
  end

  # --- naming: min_addr / max_addr re-introduced with axis-aware semantics ---
  #
  # E.7 retired the legacy *_addr family in favor of *_index.  Later,
  # PROPOSAL_TAKE_ALONG_AXIS follow-up (2026-06-08) re-introduced
  # min_addr / max_addr as siblings of sort_addr(axis:) -- the axis-
  # aware variants that return view-flat addresses, paired with
  # min_index / max_index (axis-local positions).  axis-nil delegates
  # to *_index, so the original rename is preserved at the flat level.

  def test_min_addr_axis_nil_delegates_to_min_index
    a = CArray.float64(3)
    a[] = [3, 1, 2]
    assert_equal a.min_index, a.min_addr
  end

  def test_max_addr_axis_nil_delegates_to_max_index
    a = CArray.float64(3)
    a[] = [3, 1, 2]
    assert_equal a.max_index, a.max_addr
  end

  def test_min_addr_with_axis_returns_view_flat_addresses
    a = CArray.float64(2, 3)
    a[] = [[5, 1, 2], [3, 9, 4]]
    # axis 1: row 0 min at col 1 (addr 1), row 1 min at col 0 (addr 3)
    assert_equal [1, 3], a.min_addr(axis: 1).to_a
  end

  # --- data_type reject ---

  def test_boolean_min_max_index
    # 3.0: boolean sorts/reduces as 0/1 numeric; min_index/max_index
    # return the position of the first false / first true.
    a = CArray.boolean(5)
    a[] = [0, 1, 0, 1, 0]
    assert_equal 0, a.min_index   # first 0 (false)
    assert_equal 1, a.max_index   # first 1 (true)
  end
end
