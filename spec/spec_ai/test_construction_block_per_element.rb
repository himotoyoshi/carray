# MEMO_GALAPAGOS_ESCAPE.md 2026-05-28 + (later revision):
# CArray.TYPE(dims) { ... } construction block is per-element sugar of
# map_index!.  The block receives the multi-dimensional subscript as
# individual integer arguments, so |i|, |i,j|, |i,j,k| all work
# uniformly across ranks.  Forms that want the whole subscript as an
# Array should write |*idx|.
#
# This is a 3.0 breaking change from the old whole-array yield
# semantics (= "called once, broadcast the return value").  Migration
# path for the old idiom = `.tap { |a| a[] = WHOLE_VALUE }`.

require 'test/unit'
require 'carray'

class TestConstructionBlockPerElement < Test::Unit::TestCase

  # ---- subscript yield form ----

  def test_split_form_two_dim
    a = CArray.int32(3, 3) { |i, j| i * 10 + j }
    assert_equal [[0, 1, 2], [10, 11, 12], [20, 21, 22]], a.to_a
  end

  def test_single_arg_form_one_dim
    # 1-D: |i| receives the integer (3.0 uniform individual-args form).
    a = CArray.int32(4) { |i| i * i }
    assert_equal [0, 1, 4, 9], a.to_a
  end

  def test_splat_form_receives_subscript_array
    # |*idx| catches all index args as a single Array.
    a = CArray.int32(2, 2) { |*idx| idx.sum }
    # idx = [i, j]; idx.sum = i + j
    assert_equal [[0, 1], [1, 2]], a.to_a
  end

  def test_splat_form_one_dim
    a = CArray.int32(3) { |*idx| idx.first * 10 }
    assert_equal [0, 10, 20], a.to_a
  end

  def test_destructure_form
    a = CArray.int32(2, 3) { |i, j| i * 100 + j }
    assert_equal [[0, 1, 2], [100, 101, 102]], a.to_a
  end

  def test_3d_split_form
    a = CArray.int32(2, 2, 2) { |i, j, k| i * 100 + j * 10 + k }
    assert_equal [0, 1, 10, 11, 100, 101, 110, 111], a.to_a.flatten
  end

  # ---- scalar fill still works (per-cell stores the same value) ----

  def test_scalar_constant_fill
    a = CArray.int32(3, 3) { 7 }
    assert_equal Array.new(3) { Array.new(3) { 7 } }, a.to_a
  end

  def test_scalar_constant_fill_no_block_args
    a = CArray.int32(2, 2) { 0 }
    assert_equal [[0, 0], [0, 0]], a.to_a
  end

  # ---- equivalence to map_index! ----

  def test_equivalence_to_map_index_bang
    a = CArray.int32(3, 3) { |i, j| i * 10 + j }
    b = CArray.int32(3, 3).map_index! { |i, j| i * 10 + j }
    assert_equal a.to_a, b.to_a
  end

  def test_equivalence_to_map_index_bang_one_dim
    a = CArray.int32(5) { |i| i * i }
    b = CArray.int32(5).map_index! { |i| i * i }
    assert_equal a.to_a, b.to_a
  end

  # ---- migration path for whole-array idiom ----

  def test_tap_migration_for_whole_array_fill
    # old: CArray.int32(2, 2) { [[1, 2], [3, 4]] }
    a = CArray.int32(2, 2).tap { |x| x[] = [[1, 2], [3, 4]] }
    assert_equal [[1, 2], [3, 4]], a.to_a
  end

  def test_tap_migration_for_computed_fill
    # old: CArray.int32(4) { |x| x.seq * 2 }
    a = CArray.int32(4).tap { |x| x[] = x.seq * 2 }
    assert_equal [0, 2, 4, 6], a.to_a
  end

  # ---- boolean / float work under new semantics ----

  def test_boolean_per_element
    a = CArray.boolean(5) { |i| i.odd? ? 1 : 0 }
    assert_equal [false, true, false, true, false], a.to_a
  end

  def test_float_per_element
    a = CArray.float64(3) { |i| i + 0.5 }
    assert_equal [0.5, 1.5, 2.5], a.to_a
  end
end
