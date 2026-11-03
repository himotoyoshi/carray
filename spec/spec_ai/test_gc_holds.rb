# frozen_string_literal: true
#
# Arrays a C function makes and reads through a CArray *, and buffers it
# publishes, are valid to the collector for as long as they are used.

require "test/unit"
require "carray"

class TestGCHolds < Test::Unit::TestCase
  def under_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  # The inner count's answer is read while the output's mask is made.
  def test_count_of_values_along_an_axis
    a = CA_INT32([[1, 2, 1], [2, 2, 1], [1, 1, 1], [2, 1, 2]])
    a[0, 0] = UNDEF
    v = CA_INT32([1, 2])
    want = a.count(v, axis: 0, min_count: 4).to_a
    5.times { assert_equal(want, under_stress { a.count(v, axis: 0, min_count: 4) }.to_a) }
  end

  # The scratch of a slab over several axes that are not contiguous holds
  # object cells from the start.
  def test_map_slab_of_objects_over_axes_not_contiguous
    a = CArray.object(3, 4, 5) { Array.new(60) { |i| Rational(i, 7) } }
    want = a.map_slab(axis: [0, 2]) { |s| s.sum }.to_a
    3.times {
      junk = Array.new(500) { |i| "x" * (i % 40) }
      junk = nil
      assert_equal(want, under_stress { a.map_slab(axis: [0, 2]) { |s| s.sum } }.to_a)
    }
    twice = a.map_slab(axis: [0, 2]) { |s| s * 2 }
    3.times { assert_equal(twice.to_a, under_stress { a.map_slab(axis: [0, 2]) { |s| s * 2 } }.to_a) }
  end

  # An element's to_s can change the Array being read.
  def test_const_string_from_an_array_a_to_s_empties
    vals = nil
    o = Object.new
    o.define_singleton_method(:to_s) { vals.clear; GC.start; "x" }
    vals = [o] + Array.new(200) { |i| "s#{i}" }
    c = CArray.const_string(vals)
    assert_equal(["x", "s0", "s1"], c.to_a.first(3))
    assert_equal(201, c.elements)
  end
end
