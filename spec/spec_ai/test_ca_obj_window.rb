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

end
