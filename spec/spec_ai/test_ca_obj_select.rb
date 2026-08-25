# frozen_string_literal: true
#
# spec_ai/test_ca_obj_select.rb
#
# Tests for ca_obj_select.c
#   - CASelect: boolean-mask filtered view (created by boolean-array indexing)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCASelect < Test::Unit::TestCase

  def setup
    @a    = CArray.int(6).tap { |__a| __a[] = [10, 20, 30, 40, 50, 60] }
    @mask = CArray.boolean(6).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0] }
    @s    = @a[@mask]
  end

  def test_class
    assert_equal CASelect, @s.class
  end

  def test_elements
    assert_equal 3, @s.elements
  end

  def test_read
    assert_equal 10, @s[0]
    assert_equal 30, @s[1]
    assert_equal 50, @s[2]
  end

  def test_all_selected
    mask_all = CArray.boolean(6).fill(1)
    s = @a[mask_all]
    assert_equal @a.to_a, s.to_a
  end

  def test_none_selected
    mask_none = CArray.boolean(6).fill(0)
    s = @a[mask_none]
    assert_equal 0, s.elements
  end

  def test_dup
    copy = @s.dup
    assert_equal CASelect, copy.class
    assert_equal @s.to_a, copy.to_a
  end

  def test_gc_safety
    a    = CArray.int(100).tap { |i| i[] = i }
    mask = CArray.boolean(100).tap { |i| i[] = i % 2 }
    100.times { a[mask] }
    GC.start
    assert true, "GC did not crash after allocating many CASelects"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@s), :>, 0
  end

end
