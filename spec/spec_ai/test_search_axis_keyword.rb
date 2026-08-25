# frozen_string_literal: true
#
# spec_ai/test_search_axis_keyword.rb
#
# S.5 (PROPOSAL_SEARCH_AXIS): user-facing axis: keyword wrappers over
# legacy bsearch / search / search_nearest + their _index variants.
#
# Coverage:
#   - backward compat: axis-less calls go through legacy C method unchanged
#   - axis: keyword routes to _ki kernel
#   - _index variant dual semantic:
#     * axis なし -> N-D index (= legacy via addr2index)
#     * axis あり -> axis-k position scalar per cell (= same as _ki)
#   - positional eps still works with axis: keyword (= 3.0 breaking
#     keyword-only form deferred to S.5b)
#   - internal users (locate_addr) unaffected

require "test/unit"
require_relative "../../lib/carray"

class TestSearchAxisKeyword < Test::Unit::TestCase
  # ----------------------------------------------------------------
  # Backward compat: axis-less still hits legacy C method
  # ----------------------------------------------------------------

  def test_bsearch_no_axis_returns_legacy_integer
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal 5, a.bsearch(5.0)
    assert_nil      a.bsearch(99.0)
  end

  def test_bsearch_addr_then_addr2index_no_axis
    # 3.0: bsearch_index retired.  N-D index via composition
    # addr2index(bsearch_addr(val)) -- bsearch_addr returns scalar
    # Integer flat addr (or nil on no-match).
    a = CArray.float64(10).seq!(0.0, 1.0)
    addr = a.bsearch_addr(5.0)
    assert_equal 5, addr
    assert_equal [5], a.addr2index(addr).to_a
    assert_nil       a.bsearch_addr(99.0)
  end

  def test_search_no_axis_with_positional_eps
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal 5, a.search(5.0001, 0.001)
    assert_nil      a.search(5.0001, 0.0)
  end

  def test_search_nearest_no_axis_returns_legacy_integer
    a = CArray.float64(10).seq!(0.0, 1.0)
    assert_equal 5, a.search_nearest(5.3)
  end

  # ----------------------------------------------------------------
  # axis: keyword routes to _ki
  # ----------------------------------------------------------------

  def test_bsearch_with_axis_keyword
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    assert_equal [UNDEF, 1, UNDEF], b.bsearch(11.0, axis: 1).to_a
    # axis negative normalize
    assert_equal [UNDEF, 1, UNDEF], b.bsearch(11.0, axis: -1).to_a
  end

  def test_bsearch_addr_axis_returns_view_flat
    # 3.0 dual API: bsearch (= "index" name, axis-local position) vs
    # bsearch_addr (= "addr" name, view-flat).  For axis 1 on a 3x4 grid
    # with val 11 at (1,1): axis-local = 1, view-flat = 1*4+1 = 5.
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    assert_equal [UNDEF, 1, UNDEF], b.bsearch(11.0, axis: 1).to_a       # axis-local
    assert_equal [UNDEF, 5, UNDEF], b.bsearch_addr(11.0, axis: 1).to_a  # view-flat
  end

  def test_search_with_axis_keyword
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    assert_equal [UNDEF, 1, UNDEF], b.search(11.0, axis: 1).to_a
    # positional eps still works with axis keyword
    assert_equal [UNDEF, 1, UNDEF], b.search(11.4, 0.5, axis: 1).to_a
  end

  def test_search_addr_axis_returns_view_flat
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    assert_equal [UNDEF, 1, UNDEF], b.search(11.0, axis: 1).to_a   # axis-local
    assert_equal [UNDEF, 5, UNDEF], b.search_addr(11.0, axis: 1).to_a  # view-flat
  end

  def test_search_nearest_with_axis_keyword
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    assert_equal [3, 1, 0], c.search_nearest(11.4, axis: 1).to_a
  end

  def test_search_nearest_addr_axis_returns_view_flat
    c = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| c[i, j] = (i * 10 + j).to_f } }
    assert_equal [3, 1, 0], c.search_nearest(11.4, axis: 1).to_a       # axis-local
    # view-flat: row 0 col 3 (=3), row 1 col 1 (=5), row 2 col 0 (=8)
    assert_equal [3, 5, 8], c.search_nearest_addr(11.4, axis: 1).to_a  # view-flat
  end

  # ----------------------------------------------------------------
  # locate_addr (internal bsearch user) preserved
  # ----------------------------------------------------------------

  def test_locate_addr_unaffected_by_wrapping
    ref = CArray.float64(5).seq!(0.0, 1.0)
    self_ca = CArray.float64(3)
    self_ca[0] = 2.0; self_ca[1] = 4.0; self_ca[2] = 0.0
    assert_equal [2, 4, 0], self_ca.locate_addr(ref).to_a
  end

  # ----------------------------------------------------------------
  # axis: with CArray val (rev5: A2 1-D shared / A3 N-D per-fiber)
  # ----------------------------------------------------------------

  def test_axis_with_carray_val_1d_shared
    # rev5: self.ndim==2 で val 1-D は無条件 A2 (= shared M-query)、
    # §3.1 統一 rule: axis 1 (length 4) を val.length (= 3) に差し替え -> [3, 3]
    # (= rev4 では base_shape 一致で A2.5 [3] だったが numerics 側 2026-06-17
    # feedback で priority flip、§3.1 を全 self.ndim で preserve)
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(3)
    val[0] = 1.0; val[1] = 11.0; val[2] = 21.0
    r = b.search(val, axis: 1)
    assert_equal [3, 3], r.dim
    assert_equal [[1, UNDEF, UNDEF], [UNDEF, 1, UNDEF], [UNDEF, UNDEF, 1]], r.to_a
  end

  def test_axis_with_carray_val_a3_per_fiber_scalar_via_reshape
    # rev5: self.ndim==2 で per-fiber scalar は explicit reshape (= [N, 1]) で
    # A3 with M=1 に誘導
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    val_pf = CArray.float64(3, 1)
    val_pf[0, 0] = 1.0; val_pf[1, 0] = 11.0; val_pf[2, 0] = 21.0
    r = b.search(val_pf, axis: 1)
    assert_equal [3, 1], r.dim
    assert_equal [[1], [1], [1]], r.to_a
  end

  def test_axis_with_carray_val_1d_M_neq_base
    # self [3, 4] axis 1, val [2] -> A2 shared M=2 (= 1-D 無条件 A2)
    b = CArray.float64(3, 4)
    3.times { |i| 4.times { |j| b[i, j] = (i * 10 + j).to_f } }
    val = CArray.float64(2)
    val[0] = 1.0; val[1] = 99.0
    r = b.search_nearest(val, axis: 1)
    assert_equal [3, 2], r.dim
  end
end
