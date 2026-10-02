# frozen_string_literal: true
#
# spec_ai/test_ca_obj_shift.rb
#
# Tests for ca_obj_shift.c
#   - CAShift: shifted view with fill value at boundary
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAShift < Test::Unit::TestCase

  def setup
    @a  = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @sh = @a.shift(2)   # shift right by 2
  end

  def test_class
    assert_equal CAShift, @sh.class
  end

  def test_elements
    assert_equal 6, @sh.elements
  end

  def test_shifted_right
    # sh[i] = a[i-2]; boundary fills with 0
    assert_equal [0, 0, 1, 2, 3, 4], @sh.to_a
  end

  def test_shifted_left
    sh_neg = @a.shift(-1)
    assert_equal CAShift, sh_neg.class
    assert_equal [2, 3, 4, 5, 6, 0], sh_neg.to_a
  end

  def test_2d_shift
    a  = CArray.int(3, 3).tap { |__a| __a[] = [*1..9] }
    sh = a.shift(1, 0)   # shift row-wise by 1
    assert_equal CAShift, sh.class
  end

  def test_dup
    copy = @sh.dup
    assert_equal CAShift, copy.class
    assert_equal @sh.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(100).tap { |i| i[] = i }
    100.times { a.shift(10) }
    GC.start
    assert true, "GC did not crash after allocating many CAShifts"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@sh), :>, 0
  end

  # A shift is a window: the window's accessors answer for it.
  def test_it_answers_as_a_window
    g = CArray.int32(3, 4)
    s = g.shift(1, -2, fill_value: 5)
    assert_equal [-1, 2], s.start
    assert_equal [3, 4], s.size0
    assert_equal 5, s.fill_value
  end

end
