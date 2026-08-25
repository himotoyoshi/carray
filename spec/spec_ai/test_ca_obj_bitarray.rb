# frozen_string_literal: true
#
# spec_ai/test_ca_obj_bitarray.rb
#
# Tests for ca_obj_bitarray.c
#   - CABitarray: bit-packed virtual view (1 bit per element)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCABitarray < Test::Unit::TestCase

  def setup
    @a  = CArray.uint8(4).tap { |__a| __a[] = [0xFF, 0x0F, 0xAA, 0x55] }
    @ba = @a.bitarray
  end

  def test_class
    assert_equal CABitarray, @ba.class
  end

  def test_elements
    assert_equal 32, @ba.elements   # 4 bytes × 8 bits
  end

  def test_all_bits_set
    assert_equal true, @ba[0]          # 0xFF bit 0
    assert_equal true, @ba[7]          # 0xFF bit 7
  end

  def test_partial_bits
    # byte 1 = 0x0F = 0000_1111: bits 8-11 are 1, bits 12-15 are 0
    assert_equal true, @ba[8]
    assert_equal false, @ba[12]
  end

  def test_alternating_bits
    # byte 3 = 0x55 = 0101_0101
    assert_equal true, @ba[24]
    assert_equal false, @ba[25]
    assert_equal true, @ba[26]
  end

  def test_dup
    copy = @ba.dup
    assert_equal CABitarray, copy.class
    assert_equal @ba.to_a, copy.to_a
  end

  def test_gc_safety
    100.times { CArray.uint8(100).tap { |i| i[] = i }.bitarray }
    GC.start
    assert true, "GC did not crash after allocating many CABitarrays"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@ba), :>, 0
  end

  # --- validity bitmap -> CArray mask bridge ------------------------------
  #
  # The canonical consumer of the bit fan-out is an interop bridge: columnar
  # formats pack nulls as a validity bitmap (LSB-first, 1 = valid), and a
  # CArray mask is its complement (1 = masked).  These pin the byte order and
  # the byte-boundary behaviour that bridge depends on, with the bitmap built
  # by hand so no external producer is involved.

  # values -> packed validity bitmap bytes, LSB-first, 1 = present
  def validity_bitmap (values)
    bytes = Array.new((values.length + 7) / 8, 0)
    values.each_with_index do |v, i|
      bytes[i / 8] |= (1 << (i % 8)) unless v.nil?
    end
    bytes
  end

  # Fan a validity bitmap out into a mask.  A bridge only attaches one when
  # the source actually reports nulls, so an all-present chunk stays unmasked.
  def masked_ca (values)
    ca = CA_INT64(values.map { |v| v.nil? ? 0 : v })
    return ca unless values.any?(&:nil?)
    bytes = validity_bitmap(values)
    packed = CArray.uint8(bytes.length)
    bytes.each_with_index { |b, i| packed[i] = b }
    ca.mask = packed.bitarray.flatten[0...values.length].not
    ca
  end

  def test_validity_to_mask_bridge
    vals = [1, 2, nil, 4, nil, 6, 7, nil, 9, 10]
    ca = masked_ca(vals)
    vals.each_with_index do |v, i|
      if v.nil?
        assert_equal true, ca.is_masked[i], "index #{i} should be masked"
      else
        assert_equal false, ca.is_masked[i], "index #{i} should be present"
        assert_equal v, ca[i], "index #{i} value"
      end
    end
  end

  def test_validity_to_mask_bridge_spans_byte_boundary
    vals = (0...20).map { |i| i % 3 == 0 ? nil : i }
    ca = masked_ca(vals)
    assert_equal vals.map(&:nil?), ca.is_masked.to_a
    vals.each_with_index { |v, i| assert_equal v, ca[i] unless v.nil? }
  end

  def test_full_validity_leaves_no_masked_cell
    ca = masked_ca([10, 20, 30, 40])
    assert_equal false, ca.has_mask?
    assert_equal [10, 20, 30, 40], ca.to_a
  end

  def test_all_ones_bitmap_fans_out_to_an_all_false_mask
    packed = CArray.uint8(2) { 0xff }
    assert_equal Array.new(12, false),
                 packed.bitarray.flatten[0...12].not.to_a
  end

end
