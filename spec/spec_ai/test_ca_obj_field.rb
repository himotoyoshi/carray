# frozen_string_literal: true
#
# spec_ai/test_ca_obj_field.rb
#
# Tests for ca_obj_field.c
#   - CAField: extracts a sub-field from each element at a byte offset
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAField < Test::Unit::TestCase

  def setup
    # Parent: uint32 array; field extracts the low uint16 (offset 0)
    @a = CArray.uint32(4).tap { |__a| __a[] = [0x00010002, 0x00030004, 0x00050006, 0] }
    @f = @a.field(0, CA_UINT16)
  end

  def test_class
    assert_equal CAField, @f.class
  end

  def test_elements
    assert_equal 4, @f.elements
  end

  def test_read_low_uint16
    # Little-endian: offset 0 of 0x00010002 = 0x0002
    assert_equal 0x0002, @f[0]
    assert_equal 0x0004, @f[1]
    assert_equal 0x0006, @f[2]
  end

  def test_high_field
    fh = @a.field(2, CA_UINT16)   # bytes 2-3 = high uint16
    assert_equal 0x0001, fh[0]
    assert_equal 0x0003, fh[1]
  end

  def test_dup
    copy = @f.dup
    assert_equal CAField, copy.class
    assert_equal @f.to_a, copy.to_a
  end

  def test_gc_safety
    100.times do
      a = CArray.uint32(100).tap { |i| i[] = i }
      a.field(0, CA_UINT16)
    end
    GC.start
    assert true, "GC did not crash after allocating many CAFields"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@f), :>, 0
  end

end
