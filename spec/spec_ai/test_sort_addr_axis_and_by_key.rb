# ----------------------------------------------------------------------------
#
#  spec_ai/test_sort_addr_axis_and_by_key.rb
#
#  Tests for candidate #4 (PROPOSAL handoff 2026-06-08):
#    - a.sort_addr(axis: k)  -- new per-fiber surface (mirrors sort_index)
#    - a.sort_addr            -- legacy flat retained
#    - a.sort_addr(b, c)      -- 3.0 breaking, removed (raises ArgumentError)
#    - CArray.sort_addr(a, b, c)  -- class method retained (lex sort)
#    - a.sort_by_key(key, axis: 0)  -- vectorised key-driven sort, CARemap
#    - a.max_by_key(key) / a.min_by_key(key)
#    - 3.0 breaking: sort_by / max_by / min_by (block) and *_with removed
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestSortAddrAxisAndByKey < Test::Unit::TestCase

  # ---- sort_addr instance: no-arg legacy ----------------------------------

  def test_sort_addr_no_arg_flat_1d
    a = CA_FLOAT64([3.0, 1.0, 2.0])
    assert_equal [1, 2, 0], a.sort_addr.to_a
  end

  def test_sort_addr_no_arg_2d_preserves_shape
    a = CA_INT32([[5,4,3],[0,1,2],[8,7,6]])
    assert_equal [[3,4,5],[2,1,0],[8,7,6]], a.sort_addr.to_a
  end

  # ---- sort_addr instance: axis: kwarg ------------------------------------

  def test_sort_addr_axis_0
    a = CA_FLOAT64([[3,1,2],[6,4,5]])
    # axis=0 columns already sorted -> identity view-flat addresses
    assert_equal [[0,1,2],[3,4,5]], a.sort_addr(axis: 0).to_a
  end

  def test_sort_addr_axis_1
    a = CA_FLOAT64([[3,1,2],[6,4,5]])
    # axis=1 row [3,1,2] -> [1,2,0] in fiber-local addressing
    assert_equal [[1,2,0],[4,5,3]], a.sort_addr(axis: 1).to_a
  end

  def test_sort_addr_axis_negative
    a = CA_FLOAT64([[3,1,2],[6,4,5]])
    assert_equal a.sort_addr(axis: 1).to_a, a.sort_addr(axis: -1).to_a
  end

  def test_sort_addr_signature_parity_with_sort_index_shape
    a = CA_FLOAT64([[3,1,2],[6,4,5]])
    assert_equal a.sort_index(axis: 1).dim, a.sort_addr(axis: 1).dim
  end

  # ---- sort_addr: masked_position: -----------------------------------------

  def test_sort_addr_axis_masked_position
    a = CA_FLOAT64([0, 1, 2, 3, 4])
    a[2] = UNDEF
    assert_equal [0, 1, 3, 4, 2], a.sort_addr(axis: 0).to_a
    assert_equal [2, 0, 1, 3, 4], a.sort_addr(axis: 0, masked_position: :first).to_a
  end

  def test_sort_addr_no_arg_flat_1d_masked_position
    a = CA_FLOAT64([3.0, 1.0, 2.0])
    a[2] = UNDEF                                # [3.0, 1.0, UNDEF]
    assert_equal [1, 0, 2], a.sort_addr.to_a
    assert_equal [2, 1, 0], a.sort_addr(masked_position: :first).to_a
  end

  def test_sort_addr_no_arg_2d_masked_position_preserves_shape
    a = CA_INT32([[5,4,3],[0,1,2],[8,7,6]])
    a[0, 0] = UNDEF
    assert_equal [[3,4,5],[2,1,8],[7,6,0]], a.sort_addr.to_a
    assert_equal [[0,3,4],[5,2,1],[8,7,6]], a.sort_addr(masked_position: :first).to_a
    assert_equal [3, 3], a.sort_addr.dim.to_a
  end

  # ---- 3.0 breaking: variadic instance form removed -----------------------

  def test_sort_addr_variadic_instance_form_removed
    a = CA_INT32([1,2,3])
    b = CA_INT32([3,2,1])
    assert_raise(ArgumentError) { a.sort_addr(b) }
  end

  # ---- CArray.sort_addr class method retained for lex sort --------------------

  def test_class_sort_addr_lex_sort_retained
    a = CA_INT32([2,1,2,1])
    b = CA_INT32([4,3,2,1])
    idx = CArray.sort_addr(a, b)
    # a priority -> 1,1,2,2; within a-ties b orders: (3,1)->b=3, (1,3)->b=1,
    # (0,2)->b=4, (2,2)->b=2.  stable.
    assert_equal [3, 1, 2, 0], idx.to_a
  end

  def test_class_sort_addr_masked_position
    a = CA_INT32([2,1,2,1])
    b = CA_INT32([4,3,2,1])
    a[0] = UNDEF                                # masked cell in the priority key
    assert_equal [3, 1, 2, 0], CArray.sort_addr(a, b).to_a
    assert_equal [0, 3, 1, 2], CArray.sort_addr(a, b, masked_position: :first).to_a
  end

  # ---- sort_by_key --------------------------------------------------------

  def test_sort_by_key_returns_caremap_view
    a = CA_FLOAT64([10.0, 20.0, 30.0])
    key = CA_INT32([3, 1, 2])
    v = a.sort_by_key(key)
    assert_equal [20.0, 30.0, 10.0], v.to_a
  end

  def test_sort_by_key_axis_default_0
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[2,1,0],[2,1,0]])
    # axis=0 default: per-column sort.  Each column is length 2; key tells
    # which row goes first.  col 0: key [2,2] tie, stable -> identity
    # (0,1).  col 1: key [1,1] tie -> (0,1).  col 2: key [0,0] tie ->
    # (0,1).  So result == self.
    assert_equal a.to_a, a.sort_by_key(key, axis: 0).to_a
  end

  def test_sort_by_key_axis_1
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[3,1,2],[6,4,5]])
    # axis=1 per-row: key [3,1,2] -> order [1,2,0] -> self row gathered:
    # [20,30,10].  key [6,4,5] -> order [1,2,0] -> [50,60,40].
    assert_equal [[20,30,10],[50,60,40]], a.sort_by_key(key, axis: 1).to_a
  end

  # ---- max_by_key / min_by_key (flat scalar) ------------------------------

  def test_max_by_key_returns_self_at_key_max
    a = CA_FLOAT64([10, 20, 30, 40])
    key = CA_INT32([4, 1, 3, 2])
    assert_equal 10.0, a.max_by_key(key)
  end

  def test_min_by_key_returns_self_at_key_min
    a = CA_FLOAT64([10, 20, 30, 40])
    key = CA_INT32([4, 1, 3, 2])
    assert_equal 20.0, a.min_by_key(key)
  end

  def test_max_by_key_axis_1
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[3,1,2],[6,4,5]])
    # key max per row at col 0 -> self [10, 40]
    assert_equal [10.0, 40.0], a.max_by_key(key, axis: 1).to_a
  end

  def test_min_by_key_axis_1
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[3,1,2],[6,4,5]])
    # key min per row at col 1 -> self [20, 50]
    assert_equal [20.0, 50.0], a.min_by_key(key, axis: 1).to_a
  end

  def test_min_by_key_axis_0
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[3,1,2],[6,4,5]])
    # key min per col always row 0 -> self row 0 = [10, 20, 30]
    assert_equal [10.0, 20.0, 30.0], a.min_by_key(key, axis: 0).to_a
  end

  def test_max_by_key_axis_negative
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    key = CA_INT32([[3,1,2],[6,4,5]])
    assert_equal a.max_by_key(key, axis: 1).to_a,
                 a.max_by_key(key, axis: -1).to_a
  end

  def test_max_by_key_empty_returns_undef
    a = CA_INT32([])
    assert_equal UNDEF, a.max_by_key(a)
  end

  def test_min_by_key_empty_returns_undef
    a = CA_INT32([])
    assert_equal UNDEF, a.min_by_key(a)
  end

  # ---- 3.0 breaking: obsolete *_by and *_with removed ---------------------

  def test_sort_by_block_form_removed
    a = CA_INT32([1,2,3])
    assert_false a.respond_to?(:sort_by) || a.method(:sort_by).owner == CArray
  rescue NameError
    # method not defined: that's also acceptable
  end

  def test_max_by_block_form_removed
    a = CA_INT32([1,2,3])
    assert_false a.respond_to?(:max_by) && a.method(:max_by).owner == CArray
  end

  def test_sort_with_removed
    a = CA_INT32([1,2,3])
    assert_false a.respond_to?(:sort_with)
  end

  def test_max_with_removed
    a = CA_INT32([1,2,3])
    assert_false a.respond_to?(:max_with)
  end

  def test_min_with_removed
    a = CA_INT32([1,2,3])
    assert_false a.respond_to?(:min_with)
  end

end
