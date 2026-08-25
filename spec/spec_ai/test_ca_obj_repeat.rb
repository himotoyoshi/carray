# frozen_string_literal: true
#
# spec_ai/test_ca_obj_repeat.rb
#
# Tests for ca_obj_repeat.c
#   - CARepeat: broadcast/tile view (created via broadcast_to)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCARepeat < Test::Unit::TestCase

  def setup
    @a = CArray.int(1, 4).tap { |__a| __a[] = [1, 2, 3, 4] }
    @r = @a.broadcast_to(3, 4)   # tile along first dimension
  end

  def test_class
    assert_equal CARepeat, @r.class
  end

  def test_shape
    assert_equal [3, 4], @r.dim.to_a
  end

  def test_read
    assert_equal 1, @r[0, 0]
    assert_equal 4, @r[0, 3]
    assert_equal 4, @r[2, 3]   # repeated
  end

  def test_all_rows_identical
    rows = (0...3).map { |i| (0...4).map { |j| @r[i, j] } }
    assert_equal rows[0], rows[1]
    assert_equal rows[0], rows[2]
  end

  def test_to_a
    expected = [[1, 2, 3, 4]] * 3
    assert_equal expected, @r.to_a
  end

  def test_dup
    copy = @r.dup
    assert_equal CARepeat, copy.class
    assert_equal @r.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(1, 10).tap { |i| i[] = i }
    100.times { a.broadcast_to(5, 10) }
    GC.start
    assert true, "GC did not crash after allocating many CARepeats"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@r), :>, 0
  end

end
