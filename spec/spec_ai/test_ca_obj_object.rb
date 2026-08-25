# frozen_string_literal: true
#
# spec_ai/test_ca_obj_object.rb
#
# Tests for ca_obj_object.c
#   - CArray object type: stores arbitrary Ruby objects (VALUE)
#   - Verifies xfree fix, dmark fix (GC safety), and basic behavior

require "test/unit"
require_relative "../../lib/carray"
require "objspace"

class TestCAObjectType < Test::Unit::TestCase

  def setup
    @a = CArray.object(5)
  end

  def test_data_type
    assert_equal CA_OBJECT, @a.data_type
  end

  def test_store_and_fetch_string
    @a[0] = "hello"
    assert_equal "hello", @a[0]
  end

  def test_store_and_fetch_various_types
    @a[0] = [1, 2, 3]
    @a[1] = { key: "value" }
    @a[2] = :symbol
    @a[3] = 3.14
    assert_equal [1, 2, 3],      @a[0]
    assert_equal({ key: "value" }, @a[1])
    assert_equal :symbol,        @a[2]
    assert_in_delta 3.14, @a[3], 1e-10
  end

  def test_gc_does_not_crash
    a = CArray.object(10)
    10.times { |i| a[i] = "object_#{i}" }
    GC.start
    assert_equal "object_0", a[0]
    assert_equal "object_9", a[9]
  end

  def test_gc_compact_does_not_crash
    a = CArray.object(10)
    10.times { |i| a[i] = "val_#{i}" }
    GC.compact if GC.respond_to?(:compact)
    assert_equal "val_0", a[0]
    assert_equal "val_9", a[9]
  end

  def test_dup
    @a[0] = "hello"
    @a[1] = 42
    copy = @a.dup
    assert_equal "hello", copy[0]
    assert_equal 42,      copy[1]
  end

  def test_gc_safety_bulk
    100.times do
      a = CArray.object(10)
      10.times { |i| a[i] = "str_#{i}" }
    end
    GC.start
    assert true, "GC did not crash after allocating many object CArrays"
  end

  def test_memsize
    assert_operator ObjectSpace.memsize_of(@a), :>, 0
  end

end
