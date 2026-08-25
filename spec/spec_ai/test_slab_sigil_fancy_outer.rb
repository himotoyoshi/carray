require "test/unit"
require "carray"

# SI.3.x: slab sigil (:>) accepts any outer-slot index type.  Previously
# only Integer / Range / nil reached the iterator dispatcher; boolean
# masks or CArray indices in outer slots raised
# `TypeError: can't convert Symbol into Integer` because the classifier
# routed to CA_REG_SELECT / CA_REG_GRID and the Symbol :> leaked into
# scalar coercion downstream.
#
# Fix: pre-strip :> -> nil and Integer -> length-1 Range in
# rb_ca_fetch_method, recurse through regular dispatch, then wrap in
# CASlabIterator.

class TestSlabSigilFancyOuter < Test::Unit::TestCase

  def setup
    @ca = CArray.float64(5, 5, 3, 3).seq
    @s  = CArray.int32(5).seq
  end

  # --- baseline: nil / Range / Integer outer (was already working) ---

  def test_baseline_nil_outer
    v = @ca[nil, nil, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 25, slabs.size
    assert_equal [3, 3], slabs.first.shape
  end

  def test_baseline_range_outer
    v = @ca[2..3, 1..3, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 6, slabs.size
  end

  def test_baseline_integer_outer
    # Integer is promoted to length-1 Range so the base view keeps ndim.
    v = @ca[2, nil, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    ref = v.instance_variable_get(:@reference)
    assert_equal [1, 5, 3, 3], ref.shape
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 5, slabs.size
    # Content: first slab should equal ca[2, 0, :, :]
    assert_equal @ca[2, 0, nil, nil].to_a, slabs.first.to_a
  end

  # --- new: boolean mask in outer slot ---

  def test_boolean_mask_outer
    v = @ca[@s > 3, nil, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    ref = v.instance_variable_get(:@reference)
    assert_kind_of CASelectAxis, ref
    assert_equal [1, 5, 3, 3], ref.shape
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 5, slabs.size
    # Content: mask picks only axis-0 index 4
    assert_equal @ca[4, 0, nil, nil].to_a, slabs.first.to_a
  end

  def test_range_plus_mask_outer
    v = @ca[2..3, @s > 3, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    ref = v.instance_variable_get(:@reference)
    assert_kind_of CAGrid, ref
    assert_equal [2, 1, 3, 3], ref.shape
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 2, slabs.size
    assert_equal @ca[2, 4, nil, nil].to_a, slabs.first.to_a
    assert_equal @ca[3, 4, nil, nil].to_a, slabs.last.to_a
  end

  def test_carray_index_outer
    idx = CA_INT([0, 2, 4])
    v = @ca[idx, nil, :>, :>]
    assert_kind_of CASlabIterator, v
    assert_equal [2, 3], v.slab_axes
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 15, slabs.size  # 3 * 5
    assert_equal @ca[0, 0, nil, nil].to_a, slabs.first.to_a
  end

  # --- :> at the front (outer = last axes) ---

  def test_slab_sigil_at_front
    v = @ca[:>, :>, nil, nil]
    assert_kind_of CASlabIterator, v
    assert_equal [0, 1], v.slab_axes
    slabs = []; v.each { |s| slabs << s.copy }
    assert_equal 9, slabs.size
    assert_equal [5, 5], slabs.first.shape
  end

  # --- store side: assignment through :> still rejected, regardless of
  #     outer slot type (previously mask outer raised TypeError instead
  #     of the clean IndexError). ---

  def test_store_through_slab_sigil_rejected_nil
    assert_raise(IndexError) { @ca[nil, nil, :>, :>] = 0 }
  end

  def test_store_through_slab_sigil_rejected_mask
    assert_raise(IndexError) { @ca[@s > 3, nil, :>, :>] = 0 }
  end

  def test_store_through_slab_sigil_rejected_range
    assert_raise(IndexError) { @ca[2..3, 1..3, :>, :>] = 0 }
  end

  # --- map / reduce composition still works on fancy outer ---

  def test_map_with_mask_outer
    # map_slab broadcasts the block's scalar return back into the slab
    # shape, so result.shape == reference.shape.
    v = @ca[@s > 3, nil, :>, :>]
    result = v.map { |slab| slab + 1.0 }
    assert_kind_of CArray, result
    assert_equal [1, 5, 3, 3], result.shape
    assert_equal (@ca[4, 0, nil, nil] + 1.0).to_a, result[0, 0, nil, nil].to_a
  end

  def test_reduce_with_mask_outer
    # reduce_slab (block form) collapses the slab axes -> shape == outer.
    v = @ca[@s > 3, nil, :>, :>]
    result = v.reduce { |slab| slab.sum }
    assert_kind_of CArray, result
    assert_equal [1, 5], result.shape
    assert_equal @ca[4, 0, nil, nil].sum, result[0, 0]
  end
end
