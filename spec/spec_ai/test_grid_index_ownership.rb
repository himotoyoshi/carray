# spec_ai/test_grid_index_ownership.rb
#
# A CAGrid owns the index arrays it was built from.
#
# - `dup` gets its own copy, so it keeps its values after the source view
#   is collected.
# - An index out of range raises before the copy is taken, so a raise
#   leaves nothing behind.  The index here is 64 K entries (512 KB copied),
#   so a leak shows far above the 4 KB threshold (utils/measure_leak.rb,
#   macOS only).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestGridIndexOwnership < Test::Unit::TestCase

  def test_dup_outlives_source
    a = CArray.int32(100) { |i| i }
    i = CArray.int64(50) { |k| 99 - k }
    v = a[i]
    assert_kind_of CAGrid, v
    d = v.dup
    v = nil
    5.times do
      GC.start
      10000.times { CArray.int64(50) { 7 } }
    end
    assert_equal (50..99).to_a.reverse, d.to_a
  end

  def test_dup_is_independent_of_source_index_array
    a = CArray.int32(10) { |i| i }
    i = CArray.int64(3) { |k| k }
    v = a[i]
    d = v.dup
    i[0] = 9
    assert_equal [0, 1, 2], d.to_a
    assert_equal [0, 1, 2], v.to_a
  end

  def test_out_of_range_index_raises
    a = CArray.int32(4)
    i = CArray.int64(8) { 0 }
    i[-1] = 10
    assert_raise(IndexError) { a[i] }
  end

  def test_out_of_range_index_does_not_leak
    bytes = LeakMeter.bytes_per_call(
      "a[i]",
      setup: "a = CArray.int32(4); i = CArray.int64(1 << 16) { 0 }; i[-1] = 10")
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 4096,
                    "a[i] with a bad index grew the malloc zone #{bytes.round} bytes per call"
  end

end
