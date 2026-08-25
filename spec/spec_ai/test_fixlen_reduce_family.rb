# frozen_string_literal: true
#
# CA_FIXLEN reduce-family dialect (3.0).
#
# Pins min / max / min_index / max_index on fixlen (packed fixed-length
# byte blobs), ordered by memcmp lexicographic order -- the SAME total
# order the fixlen sort family gives.  Backed by the mkkernel reduce
# `fixlen:` branch (index-only accumulator + memcmp, no CA_SLAB_REDUCE_T).
#
#   min / max              -> extremum blob (String flat, CA_FIXLEN per-axis)
#   min_index / max_index  -> position of the extremum (i64), first-wins ties
#
# Masked cells are skipped (mask_policy :min_count); an all-masked slab
# yields UNDEF (full reduction) or a masked output cell (per-axis) --
# mirroring the numeric min / max / argmin.

require "test/unit"
require "carray"

class TestFixlenReduceFamily < Test::Unit::TestCase

  # 6 distinct 3-byte keys with a duplicate ("ant") to exercise tie order.
  def keys
    CA_FIXLEN(%w[dog ant cat ant bee fig], bytes: 3)
  end

  # 2x4 grid of 3-byte keys for the per-axis cases.
  def grid
    CA_FIXLEN(%w[cat ant dog bee elk fig owl bug], bytes: 3).reshape(2, 4)
  end

  # ---- flat reduction ----------------------------------------------------

  def test_flat_min_max
    a = keys
    assert_equal("ant", a.min)
    assert_equal("fig", a.max)
  end

  def test_flat_min_max_index
    a = keys
    assert_equal(1, a.min_index)   # first "ant"
    assert_equal(5, a.max_index)   # "fig"
  end

  # The extremum + its position agree bit-for-bit with sort_index (both use
  # memcmp lexicographic order; first-wins on ties matches stable argsort).
  def test_memcmp_order_parity_with_sort_index
    a  = keys
    si = a.sort_index.to_a
    assert_equal(a[si[0]],  a.min)
    assert_equal(si[0],     a.min_index)
    assert_equal(a[si[-1]], a.max)
  end

  # ---- masked ------------------------------------------------------------

  def test_flat_skip_masked
    a = keys
    a[1] = UNDEF               # mask the first "ant"
    assert_equal("ant", a.min)      # the second "ant" (index 3) survives
    assert_equal(3, a.min_index)
  end

  def test_flat_all_masked_is_undef
    a = keys
    a[] = UNDEF
    assert_equal(UNDEF, a.min)
    assert_equal(UNDEF, a.max)
    assert_equal(UNDEF, a.min_index)
    assert_equal(UNDEF, a.max_index)
  end

  # ---- per-axis ----------------------------------------------------------

  def rows(g)
    (0...g.dim[0]).map { |i| g[i, nil].copy }
  end

  def test_per_axis_min_max
    g = grid
    assert_equal(rows(g).map(&:min), g.min(axis: 1).to_a)
    assert_equal(rows(g).map(&:max), g.max(axis: 1).to_a)
  end

  def test_per_axis_min_max_index
    g = grid
    assert_equal(rows(g).map(&:min_index), g.min_index(axis: 1).to_a)
    assert_equal(rows(g).map(&:max_index), g.max_index(axis: 1).to_a)
  end

  # min over axis 0 keeps axis 1 (columnwise memcmp min).
  def test_per_axis_min_axis0
    g = grid
    cols = (0...g.dim[1]).map { |j| g[nil, j].copy.min }
    assert_equal(cols, g.min(axis: 0).to_a)
  end

  # Per-axis output data_type: min / max stay CA_FIXLEN (width preserved),
  # min_index / max_index are int64.
  def test_per_axis_output_types
    g = grid
    m = g.min(axis: 1)
    assert_equal(CA_FIXLEN, m.data_type)
    assert_equal(3, m.bytes)
    assert_equal(CA_INT64, g.min_index(axis: 1).data_type)
  end

  # A fully-masked slab produces a masked output cell (not a bogus value).
  def test_per_axis_all_masked_row
    g = grid
    g[0, nil] = UNDEF
    m = g.min(axis: 1)
    assert_equal([true, false], m.is_masked.to_a)   # bulk bool -> Integer 0/1
    assert_equal(rows(g)[1].min, m[1])
  end
end
