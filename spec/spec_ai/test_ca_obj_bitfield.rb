# frozen_string_literal: true
#
# spec_ai/test_ca_obj_bitfield.rb
#
# Tests for ca_obj_bitfield.c
#   - CABitfield: extracts a bit-range from each element as a new type
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCABitfield < Test::Unit::TestCase

  def setup
    @a  = CArray.uint8(4).tap { |__a| __a[] = [0xFF, 0x0F, 0xAA, 0x55] }
    @bf = @a.bitfield(0..3, CA_UINT8)   # extract low 4 bits
  end

  def test_class
    assert_equal CABitfield, @bf.class
  end

  def test_elements
    assert_equal 4, @bf.elements
  end

  def test_low_nibble_ff
    assert_equal 0x0F, @bf[0]   # low 4 bits of 0xFF = 15
  end

  def test_low_nibble_0f
    assert_equal 0x0F, @bf[1]   # low 4 bits of 0x0F = 15
  end

  def test_low_nibble_aa
    assert_equal 0x0A, @bf[2]   # low 4 bits of 0xAA = 10
  end

  def test_low_nibble_55
    assert_equal 0x05, @bf[3]   # low 4 bits of 0x55 = 5
  end

  def test_high_nibble
    bf_high = @a.bitfield(4..7, CA_UINT8)
    assert_equal 0x0F, bf_high[0]  # high 4 bits of 0xFF = 15
    assert_equal 0x00, bf_high[1]  # high 4 bits of 0x0F = 0
    assert_equal 0x0A, bf_high[2]  # high 4 bits of 0xAA = 10
  end

  def test_dup
    copy = @bf.dup
    assert_equal CABitfield, copy.class
    assert_equal @bf.to_a, copy.to_a
  end

  def test_gc_safety
    100.times { CArray.uint8(100).tap { |i| i[] = i }.bitfield(0..3, CA_UINT8) }
    GC.start
    assert true, "GC did not crash after allocating many CABitfields"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@bf), :>, 0
  end

end
