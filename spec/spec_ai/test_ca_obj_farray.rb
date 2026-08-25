# frozen_string_literal: true
#
# spec_ai/test_ca_obj_farray.rb
#
# Tests for ca_obj_farray.c
#   - CAFarray: Fortran-order (column-major) view — reverses dimension order
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAFarray < Test::Unit::TestCase

  def setup
    # C order: a[row, col] = 1..6
    @a  = CArray.int(2, 3).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @fa = @a.farray
  end

  def test_class
    assert_equal CAFarray, @fa.class
  end

  def test_shape_reversed
    assert_equal [3, 2], @fa.dim.to_a   # [ncols, nrows]
  end

  def test_read
    # fa[col, row] == a[row, col]
    assert_equal 1, @fa[0, 0]   # a[0,0]
    assert_equal 2, @fa[1, 0]   # a[0,1]
    assert_equal 3, @fa[2, 0]   # a[0,2]
    assert_equal 4, @fa[0, 1]   # a[1,0]
    assert_equal 6, @fa[2, 1]   # a[1,2]
  end

  def test_roundtrip
    assert_equal @a.to_a, @fa.farray.to_a
  end

  def test_dup
    copy = @fa.dup
    assert_equal CAFarray, copy.class
    assert_equal @fa.to_a, copy.to_a
  end

  def test_gc_safety
    100.times { CArray.int(10, 20).tap { |i| i[] = i }.farray }
    GC.start
    assert true, "GC did not crash after allocating many CAFarrays"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@fa), :>, 0
  end

end
