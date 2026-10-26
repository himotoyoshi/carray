# frozen_string_literal: true
#
# spec_ai/test_ca_obj_reduce.rb
#
# Tests for ca_obj_reduce.c
#   - CAReduce: internal type created automatically when masking a CARefer
#     with a byte-ratio != 1 (e.g., uint8 array referred as uint32).
#   - No direct Ruby API — tested via the code path that creates it.
#   - Verifies xfree fix (GC safety via masked CARefer).

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAReduceViaRefer < Test::Unit::TestCase

  def test_masked_refer_does_not_crash
    # uint8[8] referred as uint32[2] with mask → CAReduce created internally
    a = CArray.uint8(8).tap { |__a| __a[] = [0, 1, 2, 3, 4, 5, 6, 7] }
    a.mask = CArray.boolean(8).tap { |__a| __a[] = [0, 0, 0, 0, 1, 0, 0, 0] }
    r = a.refer(CA_UINT32, [2])
    assert_not_nil r
    assert_equal 2, r.elements
  end

  def test_gc_safety_masked_refer
    100.times do
      a = CArray.uint8(100).tap { |i| i[] = i }
      a.mask = CArray.boolean(100).tap { |i| i[] = i % 4 == 0 }
      a.refer(CA_UINT32, [25])
    end
    GC.start
    assert true, "GC did not crash after masked CARefer (CAReduce path)"
  end

  def test_unmasked_refer_is_not_reduce
    a = CArray.uint8(8).tap { |__a| __a[] = [*0..7] }
    r = a.refer(CA_UINT32, [2])
    assert_equal 0, r.mask
  end

  def masked_bytes (a)
    a.mask.to_a.each_with_index.select { |b, _| b }.map(&:last)
  end

  # Writing values through a widening refer sends its mask cells back
  # too.  A cell that was masked stays as it was, so the parent bytes
  # under it that were not masked stay unmasked, inside the written
  # region and outside it.
  def test_writing_values_does_not_spread_the_parent_mask
    stores = {
      "grid"      => ->(f) { f[CA_INT64([3, 1])] = CA_FLOAT64([1.5, 2.5]) },
      "selection" => ->(f) { f[CA_BOOLEAN([0, 1, 0, 1, 0])] = CA_FLOAT64([2.5, 1.5]) },
      "bang"      => ->(f) { f.add!(0.0) },
    }
    stores.each do |name, store|
      r = CArray.int8(41).seq!
      r[CA_INT64([2, 20])] = UNDEF
      store.(r.refer(:float64, [5], offset: 1))
      assert_equal [2, 20], masked_bytes(r), name
    end
    r = CArray.int8(481).seq!
    r[240] = UNDEF
    r.refer(:float64, [12, 5])[5..11, 1..4].add!(0.0)
    assert_equal [240], masked_bytes(r), "bang on a block"
  end

  def test_writing_undef_masks_the_parent_cells_under_it
    r = CArray.int8(16).seq!
    f = r.refer(:float64, [2])
    f[1] = UNDEF
    assert_equal [*8..15], masked_bytes(r)
    f.mask[] = 0
    assert_equal [], masked_bytes(r)
  end

end
