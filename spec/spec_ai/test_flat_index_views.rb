# frozen_string_literal: true
#
# spec_ai/test_flat_index_views.rb
#
# Tier 2.A integration tests for CASelect and CAMapping after they were
# wired through the per-axis descriptor engine.  Validates:
#
#   - binary identity vs an independent Ruby-side ground truth
#   - view.ndim != descriptor.ndim handling (CAMapping LUT shape)
#   - duplicate INDEX last-write-wins (CAMapping scatter)
#   - mid-chain transparency (CAMapping -> CASelect, CASelect over
#     non-contig parents)
#   - MIGRATION_CASELECT_COPY: selector snapshot semantics
#   - S1 (axis-merge) + S2 (prefix pre-classify) automatic inheritance
#     by the new flat-index views (positive functional test, not bench)

require "test/unit"
require_relative "../../lib/carray"

class TestFlatIndexViews < Test::Unit::TestCase

  # ---------------------------------------------------------------
  # Helpers — slow ground-truth paths
  # ---------------------------------------------------------------

  # Gather via per-element iteration on parent (no engine).
  def gt_select_gather (parent, mask)
    flat = parent.flatten
    out = []
    flat.each_with_addr do |v, i|
      out << v if mask[i]
    end
    result = CArray.new(parent.data_type, [out.size])
    out.each_with_index { |v, i| result[i] = v }
    result
  end

  def gt_mapping_gather (parent, mapper)
    flat = parent.flatten
    out = CArray.new(parent.data_type, mapper.dim.to_a)
    mapper.each_with_addr do |idx, vi|
      pos = []
      addr = vi
      mapper.dim.to_a.reverse.each do |d|
        pos.unshift(addr % d); addr /= d
      end
      out[*pos] = flat[idx]
    end
    out
  end

  # ---------------------------------------------------------------
  # CASelect gather: binary identity
  # ---------------------------------------------------------------

  def test_caselect_1d_gather
    a = CArray.int(12).seq
    m = CArray.boolean(12).tap { |__a| __a[] = Array.new(12) { |i| i.odd? ? 1 : 0 } }
    v = a[m]
    assert_equal CASelect, v.class
    assert_equal gt_select_gather(a, m).to_a, v.to_a
  end

  def test_caselect_2d_parent
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4, 3).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0] }
    v = a[m]
    # CASelect treats parent as flat — view.ndim == 1.
    assert_equal CASelect, v.class
    assert_equal [6], v.dim.to_a
    assert_equal gt_select_gather(a, m).to_a, v.to_a
  end

  def test_caselect_all_true
    a = CArray.int(8).seq
    m = CArray.boolean(8).fill(1)
    v = a[m]
    assert_equal a.to_a, v.to_a
  end

  def test_caselect_none_true
    a = CArray.int(8).seq
    m = CArray.boolean(8).fill(0)
    v = a[m]
    assert_equal 0, v.elements
    assert_equal [], v.to_a
  end

  def test_caselect_masked_selector_cells_are_false
    a = CArray.int(8).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 1, 0, 1, 1, 0, 1, 1] }
    m.mask = CArray.boolean(8).tap { |__a| __a[] = [0, 1, 0, 0, 1, 0, 0, 0] }  # mask cells 1, 4
    v = a[m]
    # Cells 1 and 4 are masked -> treated as false; remaining TRUE cells
    # are 0, 3, 6, 7.
    assert_equal [0, 3, 6, 7], v.to_a
  end

  # ---------------------------------------------------------------
  # CASelect scatter / fill
  # ---------------------------------------------------------------

  def test_caselect_scatter
    a = CArray.int(8).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0] }
    v = a[m]
    src = CArray.int(4).tap { |__a| __a[] = [100, 200, 300, 400] }
    v[] = src
    assert_equal [100, 1, 200, 3, 300, 5, 400, 7], a.to_a
  end

  def test_caselect_fill
    a = CArray.int(8).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [0, 1, 0, 1, 0, 1, 0, 1] }
    a[m] = 99
    assert_equal [0, 99, 2, 99, 4, 99, 6, 99], a.to_a
  end

  # ---------------------------------------------------------------
  # MIGRATION_CASELECT_COPY: selector snapshot semantics
  # ---------------------------------------------------------------

  def test_selector_mutation_after_construction_does_not_affect_view
    a = CArray.int(8).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0] }
    v = a[m]
    assert_equal [0, 2, 4, 6], v.to_a
    # Mutate selector after view construction
    m[3] = 1   # would add a TRUE position if live-reference
    # view should NOT see the mutation (snapshot semantics)
    assert_equal 4, v.elements
    assert_equal [0, 2, 4, 6], v.to_a
  end

  # ---------------------------------------------------------------
  # CAMapping gather: shape preservation
  # ---------------------------------------------------------------

  def test_camapping_1d_gather
    a = CArray.int(10).seq + 100
    m = CArray.int(4).tap { |__a| __a[] = [0, 2, 5, 9] }
    v = a[m]
    # After R.3 (CAMapping removal): a[m] with 1-D mapper routes to CAGrid
    # directly via CA_REG_GRID; with N-D mapper it builds a normalize chain
    # (CAStride flatten <- CAGrid <- CAStride reshape).  Class identity is
    # an internal detail of the chain; semantic assertions follow.
    assert_equal [4], v.dim.to_a
    assert_equal [100, 102, 105, 109], v.to_a
  end

  def test_camapping_lut_shape_preserved
    # LUT use case: parent (1-D) + mapper (2-D) -> view inherits mapper.shape.
    bt = CArray.float64(256).seq * 0.5
    ir = CArray.int(3, 4).tap { |__a| __a[] = Array.new(12) { |i| i * 10 } }
    img = bt[ir]
    assert_equal [3, 4], img.dim.to_a
    # value at (i,j) = bt[i*4+j*10... wait the mapper is i*10] = (i*10) * 0.5
    expected = Array.new(3) { |i| Array.new(4) { |j| ((i * 4 + j) * 10) * 0.5 } }
    assert_equal expected, img.to_a
  end

  def test_camapping_3d_mapper_shape
    a = CArray.int(100).seq
    m = CArray.int(2, 3, 4).tap { |__a| __a[] = Array.new(24) { |i| i * 4 } }
    v = a[m]
    assert_equal [2, 3, 4], v.dim.to_a
    assert_equal gt_mapping_gather(a, m).to_a, v.to_a
  end

  # ---------------------------------------------------------------
  # CAMapping scatter: last-write-wins for duplicate INDEX
  # ---------------------------------------------------------------

  def test_camapping_scatter_unique_mapper
    a = CArray.int(8).seq
    m = CArray.int(3).tap { |__a| __a[] = [1, 3, 5] }
    v = a[m]
    v[] = CArray.int(3).tap { |__a| __a[] = [-10, -30, -50] }
    assert_equal [0, -10, 2, -30, 4, -50, 6, 7], a.to_a
  end

  def test_camapping_scatter_duplicate_mapper_last_write_wins
    a = CArray.int(5).seq
    # Three writes to position 0, one to position 1.  Engine iterates
    # output row-major, so position 0 gets 10, 20, 40 in that order
    # (last write = 40).
    m = CArray.int(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    v = a[m]
    v[] = CArray.int(4).tap { |__a| __a[] = [10, 20, 30, 40] }
    assert_equal [40, 30, 2, 3, 4], a.to_a
  end

  def test_camapping_fill
    a = CArray.int(8).seq
    m = CArray.int(2, 2).tap { |__a| __a[] = [0, 2, 4, 6] }
    a[m] = 99
    assert_equal [99, 1, 99, 3, 99, 5, 99, 7], a.to_a
  end

  def test_camapping_fill_with_duplicate_mapper
    a = CArray.int(5).fill(0)
    m = CArray.int(6).tap { |__a| __a[] = [0, 1, 0, 1, 2, 0] }
    a[m] = 7
    # Every target cell is hit at least once with 7 -> all equal 7
    assert_equal [7, 7, 7, 0, 0], a.to_a
  end

  # ---------------------------------------------------------------
  # mid-chain transparency
  # ---------------------------------------------------------------

  def test_caselect_over_non_contig_parent_view
    # parent is a non-contig CABlock view, child is CASelect
    a = CArray.int(10, 10).seq
    parent_view = a[1..3, nil]    # CABlock, 3x10
    flat_idx = CArray.boolean(30).tap { |__a| __a[] = Array.new(30) { |i| i % 3 == 0 } }
    v = parent_view[flat_idx]
    # Ground truth via slow path
    expected = gt_select_gather(parent_view, flat_idx)
    assert_equal expected.to_a, v.to_a
  end

  def test_camapping_then_caselect_chain
    # bt[ir_level] -> CAMapping (2-D), then filter through CASelect
    bt = CArray.float64(256).seq * 0.5
    ir = CArray.int(3, 4).tap { |__a| __a[] = Array.new(12) { |i| i * 10 } }
    img = bt[ir]                  # CAMapping, shape [3, 4]
    threshold_mask = CArray.boolean(3, 4).tap { |__a| __a[] = Array.new(12) { |i| i > 5 ? 1 : 0 } }
    bright = img[threshold_mask]  # CASelect over CAMapping
    assert_equal CASelect, bright.class
    # Expected: img elements where i > 5 (i = 6..11) at multiplier 10 * 0.5 = 5
    expected = (6..11).map { |i| (i * 10) * 0.5 }
    assert_equal expected, bright.to_a
  end

  def test_camapping_with_partial_csa_parent
    # CSA parent (per-axis mask) -> CAMapping over the resulting view
    a = CArray.int(5, 4).seq
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 0, 1, 1, 0] }
    csa_view = a[m, nil]        # CASelectAxis, shape [3, 4]
    mapper = CArray.int(2).tap { |__a| __a[] = [0, 11] }
    v = csa_view[mapper]
    # flat[0] of csa_view = parent[0,0] = 0
    # flat[11] of csa_view = parent[2,3] = 11  (csa_view rows are
    # [0,1,2,3], [8,9,10,11], [12,13,14,15]; flat addr 11 = row 2 col 3)
    assert_equal [0, 15], v.to_a
  end

  # ---------------------------------------------------------------
  # S1 + S2 auto-inheritance — functional test (not bench)
  # ---------------------------------------------------------------

  def test_caselect_engine_passes_full_dataset
    # Large gather to confirm the engine path (which now flows through
    # S1 axis-merge and S2 prefix pre-classify) handles non-trivial
    # sizes without regression.
    a = CArray.float64(1000).seq
    m = CArray.boolean(1000).tap { |__a| __a[] = Array.new(1000) { |i| i % 7 == 0 } }
    v = a[m]
    expected = (0...1000).step(7).map(&:to_f)
    assert_equal expected.size, v.elements
    assert_equal expected, v.to_a
  end

  def test_camapping_engine_passes_2d_shape
    a = CArray.float64(1000).seq
    m = CArray.int(20, 25).tap { |__a| __a[] = Array.new(500) { |i| (i * 2) % 1000 } }
    v = a[m]
    assert_equal [20, 25], v.dim.to_a
    # Spot-check a few cells
    assert_equal 0.0, v[0, 0]
    assert_equal 2.0, v[0, 1]
    assert_equal 998.0, v[19, 24]
  end

  # ---------------------------------------------------------------
  # data_type variety
  # ---------------------------------------------------------------

  def test_caselect_data_type_variety
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 8).seq
      m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0] }
      v = a[m]
      assert_equal [0, 2, 4, 6], v.to_a, "data_type #{dt}"
    end
  end

  def test_camapping_data_type_variety
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 8).seq
      m = CArray.int(3).tap { |__a| __a[] = [1, 3, 5] }
      v = a[m]
      assert_equal [1, 3, 5], v.to_a, "data_type #{dt}"
    end
  end

  # ---------------------------------------------------------------
  # gather then whole-view scatter (= engine attach + sync_data round-trip)
  #
  # CASelect / CAMapping per-element writes go directly to parent
  # (bypassing ca->ptr) per the pre-framework store_addr semantics;
  # to exercise both engine directions in one operation, use whole-view
  # assignment `v[] = computed_src`, which goes through sync_data.
  # ---------------------------------------------------------------

  def test_caselect_gather_then_whole_view_scatter
    a = CArray.int(8).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0] }
    v = a[m]
    gathered = v.to_ca                  # engine gather
    transformed = gathered + 1000       # element-wise add
    v[] = transformed                   # engine scatter
    assert_equal [1000, 1, 1002, 3, 1004, 5, 1006, 7], a.to_a
  end

  def test_camapping_gather_then_whole_view_scatter
    a = CArray.int(8).seq
    m = CArray.int(2, 2).tap { |__a| __a[] = [0, 2, 4, 6] }
    v = a[m]
    gathered = v.to_ca
    transformed = gathered * 2
    v[] = transformed
    assert_equal [0, 1, 4, 3, 8, 5, 12, 7], a.to_a
  end

end
