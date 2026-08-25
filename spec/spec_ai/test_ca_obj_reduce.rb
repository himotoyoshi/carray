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

end
