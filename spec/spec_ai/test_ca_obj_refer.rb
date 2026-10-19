# frozen_string_literal: true
#
# spec_ai/test_ca_obj_refer.rb
#
# Tests for ca_obj_refer.c
#   - CARefer: reinterprets parent's data as a different type and/or shape
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCARefer < Test::Unit::TestCase

  def setup
    # 8 bytes interpreted as 4 uint16 values (little-endian)
    @a = CArray.uint8(8).tap { |__a| __a[] = [0, 1, 2, 3, 4, 5, 6, 7] }
    @r = @a.refer(CA_UINT16, [4])
  end

  def test_class
    assert_equal CARefer, @r.class
  end

  def test_elements
    assert_equal 4, @r.elements
  end

  def test_read_little_endian
    # bytes [0,1] = 0x0100 = 256
    assert_equal 0x0100, @r[0]
    # bytes [2,3] = 0x0302 = 770
    assert_equal 0x0302, @r[1]
  end

  def test_reshape
    a   = CArray.int(6).tap { |__a| __a[] = [*1..6] }
    r   = a.refer(CA_INT32, [2, 3])
    assert_equal CARefer, r.class
    assert_equal [2, 3], r.shape.to_a
    assert_equal 1, r[0, 0]
    assert_equal 6, r[1, 2]
  end

  def test_dup
    copy = @r.dup
    assert_equal CARefer, copy.class
    assert_equal @r.to_a, copy.to_a
  end

  def test_gc_safety
    100.times { CArray.uint8(100).tap { |i| i[] = i }.refer(CA_UINT32, [25]) }
    GC.start
    assert true, "GC did not crash after allocating many CARefers"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@r), :>, 0
  end

  # A scalar read as narrower elements is an array of several: no scalar
  # flag, so every method sees all of its cells.
  def test_refer_of_a_scalar_into_several_cells_is_not_a_scalar
    s = CScalar.int32
    s[] = 0x04030201
    v = s.refer(:int8, [4])
    assert_equal false, v.scalar?
    assert_equal [1, 2, 3, 4], v.to_a
    assert_equal [1, 2, 3, 4], v.copy.to_a
    assert_equal [1, 2, 3, 4], v.to_type(:int16).to_a
    assert_equal [1, 2, 3, 4], (v + 0).to_a
    assert_equal true, s.refer(:int32, [1]).scalar?
  end

end
