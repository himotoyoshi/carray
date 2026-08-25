# frozen_string_literal: true
#
# spec_ai/test_ca_obj_unbound_repeat.rb
#
# Tests for ca_obj_unbound_repeat.c
#   - CAUnboundRepeat: virtual dim for broadcasting (:* = broadcastable axis,
#     nil = keep original axis)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAUnboundRepeat < Test::Unit::TestCase

  def setup
    @a   = CArray.int(4).tap { |__a| __a[] = [1, 2, 3, 4] }
    @rep = @a.unbound_repeat(:*, nil)   # → dim [1, 4]
  end

  def test_class
    assert_equal CAUnboundRepeat, @rep.class
  end

  def test_shape
    # :* inserts a size-1 broadcastable dim; nil keeps original (4)
    assert_equal [1, 4], @rep.dim.to_a
  end

  def test_read
    assert_equal 1, @rep[0, 0]
    assert_equal 4, @rep[0, 3]
  end

  def test_multiple_broadcast_dims
    rep2 = @a.unbound_repeat(:*, :*, nil)
    assert_equal CAUnboundRepeat, rep2.class
    assert_equal [1, 1, 4], rep2.dim.to_a
  end

  def test_dup
    copy = @rep.dup
    assert_equal CAUnboundRepeat, copy.class
    assert_equal @rep.to_a, copy.to_a
  end

  def test_gc_safety
    a = CArray.int(10).tap { |i| i[] = i }
    100.times { a.unbound_repeat(:*, nil) }
    GC.start
    assert true, "GC did not crash after allocating many CAUnboundRepeats"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@rep), :>, 0
  end

end
