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
    assert_equal [3, 2], @tr.shape.to_a
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
    assert_equal [4, 2, 3], tr.shape.to_a
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

  # The axes are read as every axis argument is: negative from the end, an
  # Integer only, out of range refused naming the method and the value.
  def test_the_axes_follow_the_axis_rule
    a = CArray.int32(2, 3, 4).seq
    assert_equal a.transpose(2, 0, 1).to_a, a.transpose(-1, 0, 1).to_a
    assert_raise(TypeError) { a.transpose(1.5, 0, 2) }
    assert_raise(TypeError) { a.transpose(nil, 0, 1) }
    { [3, 0, 1] => /\Atranspose: axis 3 out of range for ndim 3\z/,
      [-4, 0, 1] => /\Atranspose: axis -4 out of range for ndim 3\z/,
      [2**64, 0, 1] => /\Atranspose: axis 18446744073709551616 out of range/,
      [0, 0, 1] => /\Atranspose: axis 0 is given twice\z/,
      [-3, 0, 1] => /\Atranspose: axis 0 is given twice\z/,
      [0, 1] => /\Atranspose: 2 axes given for ndim 3\z/ }.each do |axes, message|
      e = assert_raise(ArgumentError, axes.inspect) { a.transpose(*axes) }
      assert_match message, e.message
    end
  end

end
