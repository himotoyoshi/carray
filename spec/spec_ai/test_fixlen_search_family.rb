# frozen_string_literal: true
#
# CA_FIXLEN search-family dialect (PROPOSAL_SEARCH_SEMANTICS_UNIFY S2).
#
# Pins the per-axis search family on fixlen (packed fixed-length byte
# blobs), compared by memcmp lexicographic order -- the same total order
# the fixlen bincmp operators (`<` / `>`) already use, so a slab sorted by
# `sort(axis:)` is a valid bsearch target:
#
#   bsearch(axis:) / bsearch_addr(axis:) /
#   search(axis:) / search_addr(axis:) / find_value_index_ki(axis:)
#
# Backed by the mkkernel :search fixlen body branch (char* cell + memcmp
# over ca->bytes, query packed via rb_ca_obj2ptr).  S2 step 1 covers the
# scalar-query path (case A); a CArray query along an axis (case B/C) is
# deferred and must raise NotImplementedError until S2 step 2.

require "test/unit"
require "carray"

class TestFixlenSearchFamily < Test::Unit::TestCase

  # 1-D sorted (memcmp order) set of 3-byte keys.
  def sorted_1d
    CA_FIXLEN(%w[ant bee cat dog], bytes: 3)
  end

  # 2x3, each row independently sorted in memcmp order.
  def grid_sorted
    CA_FIXLEN(%w[ant bee cat  dog elk fig], bytes: 3).reshape(2, 3)
  end

  # ---- 1-D (full reduction returns Integer / nil) ----------------------

  def test_bsearch_1d_scalar
    f = sorted_1d
    assert_equal 2, f.bsearch_ki("cat", 0)
    assert_equal 0, f.bsearch_ki("ant", 0)
    assert_nil      f.bsearch_ki("zzz", 0)   # no-match -> nil (scalar path)
  end

  def test_search_1d_scalar
    f = sorted_1d
    assert_equal 1, f.search_ki("bee", 0)
    assert_nil      f.search_ki("xyz", 0)
  end

  def test_find_value_index_1d_scalar
    f = sorted_1d
    assert_equal 3, f.find_value_index_ki("dog", 0)
    assert_nil      f.find_value_index_ki("zzz", 0)
  end

  # ---- per-axis (array output, no-match -> UNDEF, S1 unified) ----------

  def test_bsearch_axis_per_row
    g = grid_sorted
    r = g.bsearch("bee", axis: 1)
    assert_equal [1, UNDEF], r.to_a          # row0 idx1, row1 no-match
    assert_equal [false, true],     r.is_masked.to_a
  end

  def test_search_axis_per_row
    g = grid_sorted
    r = g.search("elk", axis: 1)
    assert_equal [UNDEF, 1], r.to_a          # row1 idx1
    assert_equal [true, false],     r.is_masked.to_a
  end

  def test_bsearch_addr_axis_view_flat
    g = grid_sorted
    # row1 "fig" is at axis-local 2 -> view-flat addr 1*3 + 2 = 5
    r = g.bsearch_addr("fig", axis: 1)
    assert_equal [UNDEF, 5], r.to_a
    assert_equal [true, false],     r.is_masked.to_a
  end

  def test_search_addr_axis_view_flat
    g = grid_sorted
    r = g.search_addr("ant", axis: 1)        # row0 axis-local 0 -> flat 0
    assert_equal [0, UNDEF], r.to_a
    assert_equal [false, true],     r.is_masked.to_a
  end

  # ---- memcmp lexicographic order matches fixlen bincmp ----------------

  def test_ordering_matches_bincmp
    f = sorted_1d
    # "cat" < "dog" lexicographically; bsearch must find the right slot.
    assert_equal 2, f.bsearch_ki("cat", 0)
    assert_equal 3, f.bsearch_ki("dog", 0)
  end

  # ---- parity: legacy flat (no-axis) vs new fixlen _ki path ------------

  def test_parity_flat_scalar_matches_ki_1d
    f = sorted_1d
    %w[ant bee cat dog zzz aaa].each do |q|
      assert_equal f.bsearch(q), f.bsearch_ki(q, 0), "query=#{q}"
    end
  end

  # ---- case B/C (CArray query along an axis) ---------------------------

  def test_case_a2_shared_1d_query
    # self [2,3] axis 1, query [2] (1-D shared) -> output [2,2]: each row
    # searched for both query keys.
    g = grid_sorted
    q = CA_FIXLEN(%w[bee xyz], bytes: 3)
    r = g.bsearch(q, axis: 1)
    assert_equal [2, 2], r.dim
    # row0 [ant,bee,cat] vs [bee,xyz] -> [1, x]; row1 [dog,elk,fig] -> [x, x]
    assert_equal [[1, UNDEF], [UNDEF, UNDEF]], r.to_a
    assert_equal [[false, true], [true, true]],             r.is_masked.to_a
  end

  def test_case_a3_per_fiber_query
    # query [2,2] matching self.shape with axis dim free -> output [2,2].
    g = grid_sorted
    q = CA_FIXLEN(%w[ant cat  elk zzz], bytes: 3).reshape(2, 2)
    r = g.bsearch(q, axis: 1)
    assert_equal [2, 2], r.dim
    # row0 vs [ant,cat] -> [0,2]; row1 [dog,elk,fig] vs [elk,zzz] -> [1, x]
    assert_equal [[0, 2], [1, UNDEF]], r.to_a
  end

  def test_case_b_bytes_mismatch_raises
    g = grid_sorted
    # multi-element query of a different byte width stays on case B and is
    # rejected (no scalar coercion for blobs of a different width).
    assert_raise(ArgumentError) { g.bsearch(CA_FIXLEN(%w[bb aa], bytes: 2), axis: 1) }
  end

  def test_case_b_search_exact_query
    g = grid_sorted
    q = CA_FIXLEN(%w[cat fig], bytes: 3)
    r = g.search(q, axis: 1)
    # row0 [ant,bee,cat] vs [cat,fig] -> [2, x]; row1 [dog,elk,fig] -> [x, 2]
    assert_equal [[2, UNDEF], [UNDEF, 2]], r.to_a
  end

  # ---- S3 parity preview: flat (no-axis) vs flatten + _ki --------------

  def test_parity_flat_array_query_matches_flatten_ki
    f = sorted_1d
    q = CA_FIXLEN(%w[ant zzz dog], bytes: 3)
    flat = f.bsearch(q)
    ki   = f.flatten.bsearch(q, axis: 0)
    assert_equal flat.to_a,           ki.to_a
    assert_equal flat.is_masked.to_a, ki.is_masked.to_a
  end

  # ---- mask_self: :raise on bsearch (sorted invariant) ----------------

  def test_bsearch_raises_on_masked_self
    f = sorted_1d
    f.mask = [0, 1, 0, 0]
    assert_raise(RuntimeError) { f.bsearch_ki("cat", 0) }
  end
end
