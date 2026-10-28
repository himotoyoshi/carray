# spec_ai/test_marshal_view_without_parent.rb
#
# Marshal.dump of a view writes the view's cells, as a copy would, and
# loads back a plain array.  The parent the view reads from stays out of
# the dump: a one-cell view of a large array dumps about as small as the
# cell's copy, and an object array whose cells hold views of its other
# cells dumps when there is no cycle.

require "test/unit"
require "carray"

class TestMarshalViewWithoutParent < Test::Unit::TestCase

  def test_a_small_view_of_a_large_array_dumps_small
    big = CArray.int32(100_000).seq!
    views = {
      "block"     => big[0..0],
      "step"      => big[[0, 2, 50_000]][0..0],
      "reshape"   => big.reshape(1000, 100)[0, 0..1],
      "select"    => big[big.lt(2)],
      "grid"      => big[CA_INT64([3, 1])],
    }
    views.each do |name, v|
      size = Marshal.dump(v).size
      copy = Marshal.dump(v.copy).size
      assert_operator size, :<, copy + 200, "#{name}: #{size} bytes, the copy #{copy}"
      r = Marshal.load(Marshal.dump(v))
      assert_equal CArray, r.class, name
      assert_equal v.to_a, r.to_a, name
    end
  end

  def test_an_object_view_of_a_large_array_dumps_small
    big = CA_OBJECT((0...20_000).to_a)
    v = big[5..6]
    assert_operator Marshal.dump(v).size, :<, Marshal.dump(v.copy).size + 200
    assert_equal [5, 6], Marshal.load(Marshal.dump(v)).to_a
  end

  # The loaded array does not keep the parent of the view it was dumped
  # from, and reads as any array.
  def test_the_loaded_array_has_no_parent
    big = CArray.float64(10_000).seq!
    r = Marshal.load(Marshal.dump(big[2..3]))
    assert_equal [2.0, 3.0], r.to_a
    assert_equal false, r.respond_to?(:parent) && !r.parent.nil?
  end

  # Views of other cells of the same object array, nested without a
  # cycle, dump: cell 3 holds a view of cell 0, which holds a view of
  # cells 1..2.
  def test_views_of_other_cells_nested_without_a_cycle
    o = CA_OBJECT([nil, 10, 20, 30]).copy
    o[0..0] = [o[1..2]]
    o[3..3] = [o[0..0]]
    r = Marshal.load(Marshal.dump(o))
    assert_equal [10, 20], r[0].to_a
    assert_equal [10, 20], r[3][0].to_a
    assert_equal [10, 20], Marshal.load(Marshal.dump(o[0])).to_a
  end

  # The attributes of a view still travel with it.
  def test_attributes_still_travel
    a = CArray.int32(4).seq!
    a.set_attrs(units: "m")
    r = Marshal.load(Marshal.dump(a[1..2]))
    assert_equal({ "units" => "m" }, r.attrs.to_h)
  end
end
