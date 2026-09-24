# Regression: no view class may shadow CArray#count.
#
# CABlock and CAWindow each carried a `count` of their own -- a geometry
# accessor returning the per-axis number of cells the view exposes, taking
# no argument.  It hid CArray#count on the two view classes an indexing
# expression lands on most often, so `a[2...8].count(true)` raised
# ArgumentError and `a[2...8].count` answered a shape rather than a
# population.  The name has no defence either way: the geometry it gave
# back was exactly `shape`, which every array already answers.
#
# The accessors that say something `shape` does not -- size0 / start /
# step / offset, where the view sits in its parent -- stay.

require 'test/unit'
require 'carray'

class TestViewCountNotShadowed < Test::Unit::TestCase

  def setup
    @a = CArray.boolean(10) { |i| i.even? }
  end

  def test_block_counts_a_value
    assert_equal 3, @a[2...8].count(true)
    assert_equal 3, @a[2...8].count(false)
  end

  def test_block_with_no_argument_counts_unmasked_cells
    v = @a[2...8]
    assert_equal 6, v.count
    v[0] = UNDEF
    assert_equal 5, v.count
  end

  def test_window_counts_a_value
    # -1..8 over an 8-cell source: one margin cell at each end, and the
    # interior reads 0,1,2,0,1,2,0,1.
    w = CArray.int32(8) { |i| i % 3 }.window(-1..8)
    assert_equal [10], w.shape
    assert_equal 2, w.count(2)
    assert_equal 3, w.count(1)
  end

  def test_shift_counts_a_value
    assert_equal 1, CArray.int32(5) { |i| i }.shift(1).count(2)
  end

  def test_geometry_accessors_that_say_more_than_shape_remain
    b = CArray.int32(8, 8) { 0 }[1..6, 0..7]
    assert_equal [8, 8], b.size0
    assert_equal [1, 0], b.start
    assert_equal [1, 1], b.step
    assert_equal 0,      b.offset
    assert_equal [6, 8], b.shape
  end

  # The gate that keeps this from coming back: a `count` anywhere under
  # CArray has to accept the value to count.  An arity of 0 means the name
  # has been taken for something else.
  def test_no_subclass_defines_a_count_that_refuses_a_value
    refusers = ObjectSpace.each_object(Class).
               select { |k| k < CArray && k.name && k.instance_methods(false).include?(:count) }.
               select { |k| k.instance_method(:count).arity.zero? }.
               map(&:name).sort
    assert_equal [], refusers
  end

end
