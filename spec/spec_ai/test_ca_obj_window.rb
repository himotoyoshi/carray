# frozen_string_literal: true
#
# spec_ai/test_ca_obj_window.rb
#
# Tests for ca_obj_window.c
#   - CAWindow: sliding window view with configurable boundary handling
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAWindow < Test::Unit::TestCase

  def setup
    @a = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @w = @a.window(-1..1)   # width-3 window
  end

  def test_class
    assert_equal CAWindow, @w.class
  end

  def test_window_size
    assert_equal 3, @w.elements
  end

  def test_read_at_interior
    w = @a.window(1..3)   # covers a[1,2,3]
    assert_equal [2, 3, 4], w.to_a
  end

  def test_read_at_left_boundary
    w = @a.window(-1..1)   # positions -1(OOB), 0, 1
    assert_equal [0, 1, 2], w.to_a
  end

  def test_read_at_right_boundary
    w = @a.window(4..6)   # positions 4, 5, 6(OOB)
    assert_equal [5, 6, 0], w.to_a
  end

  def test_2d_window
    a = CArray.int(4, 4).tap { |__a| __a[] = [*1..16] }
    w = a.window(-1..1, -1..1)   # 3×3 window
    assert_equal CAWindow, w.class
    assert_equal 9, w.elements
  end

  def test_dup
    copy = @w.dup
    assert_equal CAWindow, copy.class
    assert_equal @w.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(100).tap { |i| i[] = i }
    100.times { a.window(-2..2) }
    GC.start
    assert true, "GC did not crash after allocating many CAWindows"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@w), :>, 0
  end

  #  A Symbol says the same as the String, which is the spelling CArray#windows
  #  already took.  One policy, not two ways of writing it per method.
  def test_bounds_accepts_a_symbol
    a = CA_INT([[1, 2], [3, 4]])
    assert_equal a.window(-1..2, -1..2, bounds: "nearest").to_a,
                 a.window(-1..2, -1..2, bounds: :nearest).to_a
    assert_equal a.window(-1..2, -1..2, bounds: "fill").to_a,
                 a.window(-1..2, -1..2, bounds: :fill).to_a
  end

  def test_an_unknown_symbol_bounds_still_raises
    a = CA_INT([[1, 2], [3, 4]])
    assert_raise(RuntimeError) { a.window(-1..2, -1..2, bounds: :bogus) }
    #  and the 3.0 removals keep their own message
    assert_raise(ArgumentError) { a.window(-1..2, -1..2, bounds: :reflect) }
    assert_raise(ArgumentError) { a.window(-1..2, -1..2, bounds: :periodic) }
  end

  #  A range wider than its axis is how an array is padded: this is np.pad,
  #  as a view.
  def test_a_range_wider_than_the_axis_pads
    a = CArray.int32(3, 3) { 1 }

    assert_equal [5, 5], a.window(-1..3, -1..3).shape
    assert_equal [[0, 0, 0, 0, 0],
                  [0, 1, 1, 1, 0],
                  [0, 1, 1, 1, 0],
                  [0, 1, 1, 1, 0],
                  [0, 0, 0, 0, 0]], a.window(-1..3, -1..3).to_a
    assert_equal CAWindow, a.window(-1..3, -1..3).class

    #  the margin: a constant, the nearest edge cell, or masked
    assert_equal(-1, a.window(-1..3, -1..3, fill_value: -1)[0, 0])
    assert_equal 1,  a.window(-1..3, -1..3, bounds: :nearest)[0, 0]
    assert_equal true, a.window(-1..3, -1..3, fill_value: UNDEF).is_masked[0, 0]

    #  asymmetric, per axis, said by the ranges themselves: -2..3 on a
    #  3-wide axis is two cells on the left and one on the right
    assert_equal [6, 3], a.window(-2..3, 0..2).shape
  end

  #  Writes reach the parent inside, and have nowhere to go outside.
  def test_a_write_into_the_margin_is_discarded
    row = CArray.int32(4).seq!(1)
    w = row.window(-1..4, fill_value: 0)

    w[1] = 99
    assert_equal [99, 2, 3, 4], row.to_a

    w[0] = 77
    assert_equal 0, w[0]
    assert_equal [99, 2, 3, 4], row.to_a
  end

end
