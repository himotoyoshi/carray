# frozen_string_literal: true
#
# spec_ai/test_ca_obj_array.rb
#
# Tests for ca_obj_array.c fixes:
#   - dsize (ObjectSpace.memsize_of)
#   - integer overflow protection in array creation
#   - xfree consistency (implicit: no crash on GC)
#

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"
require "objspace"

class TestDsize < Test::Unit::TestCase

  def test_memsize_of_int_array
    a = CArray.int(100, 100)
    size = ObjectSpace.memsize_of(a)
    # should report at least the data buffer size (100*100*4 = 40000 for int32)
    expected_data = 100 * 100 * a.bytes
    assert_operator size, :>=, expected_data,
      "memsize_of should report at least the data buffer size (#{expected_data}), got #{size}"
  end

  def test_memsize_of_double_array
    a = CArray.double(50, 50)
    size = ObjectSpace.memsize_of(a)
    expected_data = 50 * 50 * a.bytes
    assert_operator size, :>=, expected_data,
      "memsize_of should report at least the data buffer size (#{expected_data}), got #{size}"
  end

  def test_memsize_of_scalar
    s = CScalar.int
    size = ObjectSpace.memsize_of(s)
    # scalar should report at least sizeof struct + bytes
    assert_operator size, :>, 0,
      "memsize_of for CScalar should be > 0, got #{size}"
  end

  def test_memsize_of_object_array
    a = CArray.object(10)
    size = ObjectSpace.memsize_of(a)
    expected_data = 10 * a.bytes  # VALUE size * 10
    assert_operator size, :>=, expected_data,
      "memsize_of for object array should report at least #{expected_data}, got #{size}"
  end

  def test_memsize_of_small_vs_large
    small = CArray.int(10)
    large = CArray.int(10000)
    size_small = ObjectSpace.memsize_of(small)
    size_large = ObjectSpace.memsize_of(large)
    assert_operator size_large, :>, size_small,
      "larger array should report more memory: small=#{size_small}, large=#{size_large}"
  end
end

class TestOverflowProtection < Test::Unit::TestCase

  def test_too_large_array_raises
    # Attempt to create an array so large it exceeds CA_LENGTH_MAX
    # CA_LENGTH_MAX is 0x7fffffffffffffff for 64-bit
    # double(2^30, 2^30, 2^30) = 8 * 2^90 bytes -> exceeds CA_LENGTH_MAX
    err = assert_raise(RuntimeError) do
      CArray.double(2**30, 2**30, 2**30)
    end
    assert_match(/too large byte length/, err.message)
  end

  def test_negative_dimension_raises
    assert_raise(RuntimeError) do
      CArray.int(-1)
    end
  end

  def test_zero_dimension
    # zero-element array should be creatable without error
    a = CArray.int(0)
    assert_equal(0, a.elements)
  end
end

class TestGCConsistency < Test::Unit::TestCase

  def test_gc_does_not_crash_for_carray
    100.times { CArray.int(100, 100) }
    GC.start
    # If xfree/xmalloc mismatch existed, GC might crash or corrupt memory
    assert(true, "GC did not crash after allocating many CArrays")
  end

  def test_gc_does_not_crash_for_cscalar
    100.times { CScalar.double }
    GC.start
    assert(true, "GC did not crash after allocating many CScalars")
  end

  def test_gc_does_not_crash_for_object_array
    100.times do
      a = CArray.object(10)
      10.times { |i| a[i] = "string_#{i}" }
    end
    GC.start
    assert(true, "GC did not crash after allocating many object arrays")
  end

  def test_gc_compact_does_not_crash
    # GC.compact may move VALUE pointers
    # dcompact is still NULL, so we mainly check it doesn't segfault
    a = CArray.object(10)
    10.times { |i| a[i] = "value_#{i}" }
    if GC.respond_to?(:compact)
      GC.compact
    end
    # After compaction, the array should still be accessible
    assert_equal("value_0", a[0])
    assert_equal("value_9", a[9])
  end
end
