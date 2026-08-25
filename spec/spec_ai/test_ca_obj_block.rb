# frozen_string_literal: true
#
# spec_ai/test_ca_obj_block.rb
#
# Tests for ca_obj_block.c
#   - CABlock: strided sub-array view (created by range indexing)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCABlock < Test::Unit::TestCase

  def setup
    @a   = CArray.int(3, 4).tap { |__a| __a[] = [*1..12] }
    @blk = @a[0..1, 1..2]   # 2×2 block
  end

  def test_class
    assert_equal CABlock, @blk.class
  end

  def test_shape
    assert_equal [2, 2], @blk.dim.to_a
  end

  def test_read
    assert_equal 2,  @blk[0, 0]   # a[0,1]
    assert_equal 3,  @blk[0, 1]   # a[0,2]
    assert_equal 6,  @blk[1, 0]   # a[1,1]
    assert_equal 7,  @blk[1, 1]   # a[1,2]
  end

  def test_1d_block
    a  = CArray.int(10).tap { |__a| __a[] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90] }
    b  = a[2..5]
    assert_equal CABlock, b.class
    assert_equal [4], b.dim.to_a
    assert_equal 20, b[0]
    assert_equal 50, b[3]
  end

  def test_dup
    copy = @blk.dup
    assert_equal CABlock, copy.class
    assert_equal @blk.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(100, 100).tap { |i| i[] = i }
    100.times { a[0..49, 0..49] }
    GC.start
    assert true, "GC did not crash after allocating many CABlocks"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@blk), :>, 0
  end

end
