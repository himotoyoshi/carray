# frozen_string_literal: true
#
# spec_ai/test_ca_obj_grid.rb
#
# Tests for ca_obj_grid.c
#   - CAGrid: Cartesian-product fancy indexing view
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAGrid < Test::Unit::TestCase

  def setup
    @a   = CArray.int(6).tap { |__a| __a[] = [10, 20, 30, 40, 50, 60] }
    @idx = CArray.int(3).tap { |__a| __a[] = [5, 2, 0] }
    @g   = @a.grid(@idx)
  end

  def test_class
    assert_equal CAGrid, @g.class
  end

  def test_elements
    assert_equal 3, @g.elements
  end

  def test_read
    assert_equal 60, @g[0]   # a[5]
    assert_equal 30, @g[1]   # a[2]
    assert_equal 10, @g[2]   # a[0]
  end

  def test_2d_cartesian_grid
    a  = CArray.int(3, 3).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6, 7, 8, 9] }
    ri = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    ci = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    g  = a.grid(ri, ci)
    assert_equal CAGrid, g.class
    assert_equal [2, 2], g.dim.to_a
    assert_equal 2, g[0, 0]   # a[0,1]
    assert_equal 3, g[0, 1]   # a[0,2]
    assert_equal 8, g[1, 0]   # a[2,1]
    assert_equal 9, g[1, 1]   # a[2,2]
  end

  def test_dup
    copy = @g.dup
    assert_equal CAGrid, copy.class
    assert_equal @g.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(100).tap { |i| i[] = i }
    100.times do
      idx = CArray.int(50).tap { |i| i[] = i * 2 }
      a.grid(idx)
    end
    GC.start
    assert true, "GC did not crash after allocating many CAGrids"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@g), :>, 0
  end

end
