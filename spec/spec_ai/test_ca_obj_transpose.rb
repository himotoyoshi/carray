# frozen_string_literal: true
#
# spec_ai/test_ca_obj_transpose.rb
#
# Tests for ca_obj_transpose.c
#   - CATranspose: permuted-dimension view (generalized transpose)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCATranspose < Test::Unit::TestCase

  def setup
    @a  = CArray.int(2, 3).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @tr = @a.transpose(1, 0)
  end

  def test_class
    assert_equal CATranspose, @tr.class
  end

  def test_shape
    assert_equal [3, 2], @tr.dim.to_a
  end

  def test_read
    # tr[c, r] == a[r, c]
    assert_equal 1, @tr[0, 0]   # a[0,0]
    assert_equal 2, @tr[1, 0]   # a[0,1]
    assert_equal 3, @tr[2, 0]   # a[0,2]
    assert_equal 4, @tr[0, 1]   # a[1,0]
    assert_equal 6, @tr[2, 1]   # a[1,2]
  end

  def test_3d_transpose
    b  = CArray.int(2, 3, 4).tap { |i| i[] = i }
    tr = b.transpose(2, 0, 1)   # [4, 2, 3]
    assert_equal CATranspose, tr.class
    assert_equal [4, 2, 3], tr.dim.to_a
  end

  def test_roundtrip
    assert_equal @a.to_a, @tr.transpose(1, 0).to_a
  end

  def test_dup
    copy = @tr.dup
    assert_equal CATranspose, copy.class
    assert_equal @tr.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(10, 20).tap { |i| i[] = i }
    100.times { a.transpose(1, 0) }
    GC.start
    assert true, "GC did not crash after allocating many CATransposes"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@tr), :>, 0
  end

  def test_error_unknown_keyword
    a = CArray.float64(4, 5)
    # The axis order is positional; a keyword must not read as a count mismatch.
    assert_raise(ArgumentError) { a.transpose(axis: 0) }
    assert_raise(ArgumentError) { a.transpose(1, 0, foo: 1) }
    # 1-D would otherwise reach NUM2SIZE and raise TypeError.
    assert_raise(ArgumentError) { CArray.float64(4).transpose(axis: 0) }
  end

end
