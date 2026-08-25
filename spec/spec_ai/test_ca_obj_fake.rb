# frozen_string_literal: true
#
# spec_ai/test_ca_obj_fake.rb
#
# Tests for ca_obj_fake.c
#   - CAFake: reinterprets parent's data as a different type (same bytes)
#   - Verifies xfree fix (GC safety) and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAFake < Test::Unit::TestCase

  def setup
    @a  = CArray.int32(4).tap { |__a| __a[] = [1, 2, 3, 4] }
    @fk = @a.fake(CA_FLOAT32)
  end

  def test_class
    assert_equal CAFake, @fk.class
  end

  def test_data_type
    assert_equal CA_FLOAT32, @fk.data_type
  end

  def test_elements
    assert_equal 4, @fk.elements
  end

  def test_same_element_count_as_parent
    a64 = CArray.int64(5).tap { |__a| __a[] = [*0..4] }
    fk  = a64.fake(CA_DOUBLE)
    assert_equal a64.elements, fk.elements
  end

  def test_dup
    copy = @fk.dup
    assert_equal CAFake, copy.class
    assert_equal @fk.data_type, copy.data_type
    assert_equal @fk.elements,  copy.elements
  end

  def test_gc_safety
    100.times { CArray.int32(100).tap { |i| i[] = i }.fake(CA_FLOAT32) }
    GC.start
    assert true, "GC did not crash after allocating many CAFakes"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@fk), :>, 0
  end

end
