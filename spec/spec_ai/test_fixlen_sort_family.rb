# frozen_string_literal: true
#
# CA_FIXLEN sort-family dialect (3.0).
#
# Pins the per-axis sort family on fixlen (packed fixed-length byte
# blobs), ordered by memcmp lexicographic order -- the same total order
# the fixlen bincmp operators (`<` / `>`) already use:
#
#   sort(axis:) / sort_index(axis:) / sort_addr(axis:) /
#   rank_index(axis:) / partition(kth, axis:) /
#   partition_index(kth, axis:) / partition_copy(kth)
#
# Backed by the mkkernel :sort fixlen branch (pair {char*, nbytes, idx} +
# memcmp comparator, qsort-routed) and, for partition_copy, the revived
# ca_quickselect_bytes (cmp == NULL -> raw memcmp).

require "test/unit"
require "carray"

class TestFixlenSortFamily < Test::Unit::TestCase

  # 2x4 fixlen, each row an unsorted set of 3-byte keys (full width, so no
  # null padding ambiguity on read-back).
  def grid
    CA_FIXLEN(%w[cat ant dog bee elk fig owl bug], bytes: 3).reshape(2, 4)
  end

  def rows(g)
    (0...g.dim[0]).map { |i| g[i, nil].copy }
  end

  def test_sort_axis_per_row_view
    g = grid
    s = g.sort(axis: 1)
    assert_equal(CARemap, s.class)            # view-by-default
    assert_equal(rows(g).map { |r| r.sort.to_a }, s.to_a)
  end

  def test_sort_index_axis
    g = grid
    assert_equal(rows(g).map { |r| r.sort_index.to_a },
                 g.sort_index(axis: 1).to_a)
  end

  def test_sort_addr_axis_view_flat
    g = grid
    # view-flat addresses: row i permutes its own block {4i .. 4i+3}.
    assert_equal([[1, 3, 0, 2], [7, 4, 5, 6]], g.sort_addr(axis: 1).to_a)
  end

  def test_rank_index_axis
    g = grid
    assert_equal(rows(g).map { |r| r.rank_index.to_a },
                 g.rank_index(axis: 1).to_a)
  end

  def test_partition_index_axis_kth_exact
    g = grid
    pidx = g.partition_index(2, axis: 1)
    rows(g).each_with_index do |r, i|
      kth_val = g[i, pidx[i, 2]]
      assert_equal(r.sort[2], kth_val)        # kth position is exact
    end
  end

  def test_partition_axis_view
    g = grid
    pv = g.partition(2, axis: 1)
    assert_equal(CARemap, pv.class)
    rows(g).each_with_index { |r, i| assert_equal(r.sort[2], pv[i, 2]) }
  end

  def test_partition_copy_flat
    f = CA_FIXLEN(%w[dog ant cat bee], bytes: 3)
    part = f.partition_copy(1)
    assert_equal(f.sort_copy[1], part[1])     # kth=1 exact
  end

  def test_flat_sort_still_works
    f = CA_FIXLEN(%w[dog ant cat bee], bytes: 3)
    assert_equal(%w[ant bee cat dog], f.copy.sort.to_a)
  end

  # Ties: equal keys keep input order (stable via index tie-break).
  def test_sort_index_stable_on_ties
    g = CA_FIXLEN(%w[bb aa bb aa], bytes: 2).reshape(1, 4)
    # values: aa(1) aa(3) bb(0) bb(2) -> indices [1,3,0,2]
    assert_equal([[1, 3, 0, 2]], g.sort_index(axis: 1).to_a)
  end

  # Single-element fiber: sort/partition are no-ops.
  def test_single_element_fiber
    g = CA_FIXLEN(%w[zz aa], bytes: 2).reshape(2, 1)
    assert_equal([[0], [0]], g.sort_index(axis: 1).to_a)
    assert_equal([%w[zz], %w[aa]], g.sort(axis: 1).to_a)
  end

  # kind: :stable selects the mergesort entry; fixlen ignores do_stable
  # (qsort + tie-break is already stable) and must agree with :quick.
  def test_kind_stable_matches_quick
    g = grid
    assert_equal(g.sort(axis: 1, kind: :quick).to_a,
                 g.sort(axis: 1, kind: :stable).to_a)
  end

  # Masked input is rejected by the sort family (ordering ill-defined).
  def test_masked_input_sorts_to_masked_position
    g = grid
    g[0, 0] = UNDEF                             # row 0 becomes [UNDEF, ant, dog, bee]
    s = g.sort(axis: 1)
    assert_equal(["ant", "bee", "dog", UNDEF], s[0, nil].to_a)
    assert_equal([false, false, false, true], s[0, nil].mask.to_a)

    s_first = g.sort(axis: 1, masked_position: :first)
    assert_equal([UNDEF, "ant", "bee", "dog"], s_first[0, nil].to_a)
    assert_equal([true, false, false, false], s_first[0, nil].mask.to_a)
  end

  # ---- no-axis unification: fixlen flat sort behaves like numeric -------
  #
  # 3.0: no-axis `sort` / `sort_copy` on fixlen no longer keep the legacy
  # shape-preserving eager copy.  They flatten to 1-D and flow through the
  # same sort_addr_ki fixlen dialect + ca_remap_new path as numeric, so a
  # 2-D fixlen flattens to a 1-D result -- matching numeric direction.

  def test_flat_sort_flattens_to_1d_view
    g = grid                                    # shape (2, 4)
    s = g.sort                                  # no-axis
    assert_equal(CARemap, s.class)              # view, like numeric a.sort
    assert_equal([8], s.shape)                  # flattened to 1-D
    assert_equal(g.to_a.flatten.sort, s.to_a)
  end

  def test_flat_sort_copy_flattens_to_1d_entity
    g = grid                                    # shape (2, 4)
    s = g.sort_copy                             # no-axis
    assert_equal(CArray, s.class)               # eager entity, like numeric
    assert_equal([8], s.shape)                  # flattened to 1-D
    assert_equal(g.to_a.flatten.sort, s.to_a)
  end

  # sort_copy(axis:) sorts per-fiber (regression: the old eager flat
  # fallback ignored axis: and returned a flat-sorted reshape).
  def test_sort_copy_axis_per_row
    g = grid
    s = g.sort_copy(axis: 1)
    assert_equal(CArray, s.class)               # eager entity
    assert_equal(g.shape, s.shape)              # axis: preserves shape
    assert_equal(rows(g).map { |r| r.sort.to_a }, s.to_a)
  end

  # Shape/class parity with numeric across the no-axis / axis matrix.
  def test_shape_class_parity_with_numeric
    fg = grid                                   # fixlen (2, 4)
    ng = CArray.int32(2, 4) { |i, j| (i * 4 + j) }   # numeric (2, 4)
    [[:sort, {}], [:sort, { axis: 1 }],
     [:sort_copy, {}], [:sort_copy, { axis: 1 }]].each do |m, kw|
      fr = kw.empty? ? fg.send(m) : fg.send(m, **kw)
      nr = kw.empty? ? ng.send(m) : ng.send(m, **kw)
      assert_equal(nr.class, fr.class, "#{m} #{kw} class")
      assert_equal(nr.shape, fr.shape, "#{m} #{kw} shape")
    end
  end
end
