# frozen_string_literal: true
#
# spec_ai/test_cagrid_rebuild.rb
#
# Tier 3 / C1 (PROPOSAL_CAGRID_REBUILD) regression tests.
#
# CAGrid's internal model was rebuilt from `CArray **grid + int8_t
# *contig` (always-allocate identity arrays for nil axes, lose Range
# structure on the way to CA_SIZE(range)) to `cag_axis_t *axes`
# (per-axis tagged kind = STRIDE | INDEX).  Pins:
#
#   - nil-arg axes emit STRIDE descriptor + don't allocate identity
#     indices (memory win, dsize comparison)
#   - plain integer Range emits STRIDE descriptor (preserves
#     arithmetic-progression structure, asymmetry #1 resolved)
#   - integer CArray emits INDEX with snapshot semantics
#   - boolean CArray converts via where → INDEX (same as pre-C1)
#   - masked input CArray skips masked cells in the snapshot
#   - 1-D nil-only no longer crashes (pre-existing bug fixed)
#   - duplicate INDEX last-write-wins (asymmetry #2 preserved as spec)
#   - clone / dup preserves per-axis kind
#   - mid-chain transparency

require "test/unit"
require "objspace"
require_relative "../../lib/carray"

class TestCAGridRebuild < Test::Unit::TestCase

  # ---------- 1-D nil-only crash regression pin ----------

  def test_1d_nil_only_no_crash
    # Pre-C1: a.grid(nil) (1-D, single nil arg) crashed in setup
    # because ca_is_scalar(grid[0]) was called with grid[0]=NULL.
    # Post-C1: nil arg builds a STRIDE proto, no CArray null deref.
    a = CArray.int(5).seq
    v = a.grid(nil)
    assert_equal CAGrid, v.class
    assert_equal [5], v.dim.to_a
    assert_equal [0, 1, 2, 3, 4], v.to_a
  end

  # ---------- Range → STRIDE (asymmetry #1 resolved) ----------

  def test_range_emits_stride_describe_axes
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 1..3)
    desc = v._describe_axes
    assert_equal [:stride, 4, 0, 1], desc[0]
    assert_equal [:stride, 3, 1, 1], desc[1]
  end

  def test_range_exclusive_end
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 1...4)  # = [1, 2, 3], count = 3
    desc = v._describe_axes
    assert_equal [:stride, 3, 1, 1], desc[1]
  end

  def test_range_with_negative_endpoint
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 1..-2)  # = [1, 2, 3], count = 3 (parent.dim[1]=5, -2 -> 3)
    desc = v._describe_axes
    assert_equal [:stride, 3, 1, 1], desc[1]
  end

  def test_range_full_span_normalised_to_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 0..4)
    desc = v._describe_axes
    assert_equal [:stride, 5, 0, 1], desc[1]
  end

  # ---------- nil → STRIDE, no index allocation ----------

  def test_nil_emits_stride_describe_axes
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(3, 4, 5).seq
    v = a.grid(nil, nil, nil)
    desc = v._describe_axes
    assert_equal [:stride, 3, 0, 1], desc[0]
    assert_equal [:stride, 4, 0, 1], desc[1]
    assert_equal [:stride, 5, 0, 1], desc[2]
  end

  def test_nil_axes_save_memory_vs_index_axes
    # Compare dsize: all-nil 3D vs all-INDEX 3D of the same shape.
    # STRIDE axes contribute 0 indices bytes; INDEX axes pay
    # count * sizeof(ca_size_t).  For large dims the gap is large.
    n = 100
    a = CArray.float64(n, n, n)
    v_nil = a.grid(nil, nil, nil)
    idx = CArray.int(n).tap { |__a| __a[] = Array.new(n) { |i| i } }
    v_idx = a.grid(idx, idx, idx)
    assert_operator ObjectSpace.memsize_of(v_idx),
                    :>,
                    ObjectSpace.memsize_of(v_nil),
                    "INDEX view should hold more bytes than STRIDE view"
  end

  # ---------- Integer CArray → INDEX with snapshot ----------

  def test_integer_array_emits_index
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(5, 4).seq
    idx = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    v = a.grid(idx, nil)
    desc = v._describe_axes
    assert_equal [:index, 3, [0, 2, 4]], desc[0]
    assert_equal [:stride, 4, 0, 1],     desc[1]
  end

  def test_integer_array_snapshot_independent_of_mutation
    # Mutate the source array after CAGrid construction; the view
    # should not see the mutation (snapshot semantics).
    a = CArray.int(5).seq + 100
    idx = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    v = a.grid(idx)
    pre = v.to_a
    idx[0] = 4   # mutate source
    post = v.to_a
    assert_equal pre, post,
                 "Post-C1: CAGrid indices are snapshotted; mutation should not propagate"
  end

  # ---------- boolean → where → INDEX ----------

  def test_boolean_via_where
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    # a.grid(boolean, ...) routes to CASelectAxis (= same class as a[m, ...]).
    # Y.6: indices [0, 2, 4] form constant step 2 -> STRIDE kind promotion.
    a = CArray.int(5, 4).seq
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 0, 1, 0, 1] }
    v = a.grid(m, nil)
    desc = v._describe_axes
    assert_equal [:stride, 3, 0, 2], desc[0]
    assert_equal [:stride, 4, 0, 1], desc[1]
  end

  # ---------- masked integer CArray skips masked cells ----------

  def test_masked_integer_array_skips_masked_cells
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(5).seq + 100
    idx = CArray.int(4).tap { |__a| __a[] = [0, 1, 2, 3] }
    idx.mask = CArray.boolean(4).tap { |__a| __a[] = [0, 1, 0, 0] }  # mask cell 1
    v = a.grid(idx)
    desc = v._describe_axes
    # Masked cell 1 (= parent index 1) skipped → indices = [0, 2, 3]
    assert_equal [:index, 3, [0, 2, 3]], desc[0]
    assert_equal [100, 102, 103], v.to_a
  end

  # ---------- gather / scatter / fill basic ----------

  def test_gather_with_mixed_kinds
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 1..3)
    expected = [[1, 2, 3], [6, 7, 8], [11, 12, 13], [16, 17, 18]]
    assert_equal expected, v.to_a
  end

  def test_scatter_with_mixed_kinds
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 1..2)
    v[] = CArray.int(4, 2).tap { |__a| __a[] = Array.new(8) { |i| -i - 1 } }
    expected = [
      [0, -1, -2, 3, 4],
      [5, -3, -4, 8, 9],
      [10, -5, -6, 13, 14],
      [15, -7, -8, 18, 19]
    ]
    assert_equal expected, a.to_a
  end

  def test_fill_with_mixed_kinds
    a = CArray.int(4, 5).seq
    v = a.grid(nil, 0..2)
    v[] = -1
    a.dim[0].times do |i|
      3.times { |j| assert_equal(-1, a[i, j]) }
      (3...5).each { |j| assert_equal i * 5 + j, a[i, j] }
    end
  end

  # ---------- duplicate INDEX last-write-wins (asymmetry #2 preserved) ----------

  def test_duplicate_index_scatter_last_write_wins
    a = CArray.int(5).seq
    idx = CArray.int(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    v = a.grid(idx)
    v[] = CArray.int(4).tap { |__a| __a[] = [10, 20, 30, 40] }
    # Writes to position 0 in order: 10, 20, then 40 (last write).
    # Writes to position 1 just 30.
    assert_equal [40, 30, 2, 3, 4], a.to_a
  end

  # ---------- clone / initialize_copy ----------

  def test_clone_preserves_per_axis_kinds
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(4, 5).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    v  = a.grid(idx, 1..3)
    v2 = v.clone
    assert_equal v.to_a, v2.to_a
    assert_equal v._describe_axes, v2._describe_axes
  end

  # ---------- 3D mixed (STRIDE / INDEX / STRIDE) ----------

  def test_3d_mixed_stride_index_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(3, 4, 2).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 3] }
    v = a.grid(nil, idx, nil)
    desc = v._describe_axes
    assert_equal [:stride, 3, 0, 1],   desc[0]
    assert_equal [:index,  2, [0, 3]], desc[1]
    assert_equal [:stride, 2, 0, 1],   desc[2]
  end

  # ---------- S1 axis-merge eligibility on STRIDE Range (Tier 3 win) ----------

  def test_range_stride_axis_engaged_by_s1_merge
    # Two adjacent STRIDE axes (= Range + nil) are now mergeable
    # candidates for the engine's D8 axis-merge.  Pre-C1 this couldn't
    # happen because the Range axis was INDEX.  Functional test: result
    # binary-identity vs ground truth.
    a = CArray.int(10, 10).seq
    v = a.grid(2..5, nil)
    # ground truth via per-element
    expected = (2..5).flat_map { |i| (0...10).map { |j| i * 10 + j } }
    assert_equal expected, v.to_a.flatten
  end

  # ---------- mid-chain transparency ----------

  def test_grid_over_block_view
    # CAGrid over a CABlock parent — parent is non-contig view; tests
    # mid-chain transparency same as for CASelect/CAMapping.
    a = CArray.int(10, 10).seq
    parent_view = a[2..7, nil]   # CABlock 6x10
    v = parent_view.grid(nil, 0..4)
    expected = (0...6).map { |i| (0..4).map { |j| (i + 2) * 10 + j } }
    assert_equal expected, v.to_a
  end

  # ---------- data_type variety ----------

  def test_data_type_variety
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 4, 3).seq
      v = a.grid(nil, 0..1)
      assert_equal [[0, 1], [3, 4], [6, 7], [9, 10]], v.to_a, "data_type #{dt}"
    end
  end

  # ---------- empty axis edge case ----------

  def test_empty_integer_array
    a = CArray.int(5).seq
    idx = CArray.int(0)   # empty CArray (0 elements)
    v = a.grid(idx)
    assert_equal 0, v.elements
    assert_equal [], v.to_a
  end

end
