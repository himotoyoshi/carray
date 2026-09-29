require "test/unit"
require "carray"

class TestAttributeInherit < Test::Unit::TestCase

  def setup
    @a = CArray.float64(3, 4).seq!
    @a.set_attr(:units, "m/s")
    @b = CArray.float64(3, 4).seq!
    @b.set_attr(:units, "K")
  end

  def test_copy_keeps_attributes
    assert_equal({ "units" => "m/s" }, @a.copy.attrs)
  end

  def test_copy_of_view_keeps_merged_attributes
    v = @a[0, nil]
    v.set_attr(:slice, "row0")
    assert_equal({ "slice" => "row0", "units" => "m/s" }, v.copy.attrs)
  end

  def test_copy_attributes_are_its_own
    c = @a.copy
    c.set_attr(:units, "km/h")
    assert_equal "m/s", @a.attr(:units)
    assert_equal "km/h", c.attr(:units)
    assert_nil c.parent
  end

  def test_copy_without_attributes_has_none
    assert_equal false, CArray.int32(3).copy.has_attr?
  end

  def test_to_type_keeps_attributes
    assert_equal({ "units" => "m/s" }, @a.to_type(:float32).attrs)
    assert_equal({ "units" => "m/s" }, @a.int32.attrs)
  end

  def test_lazy_marker_walks_through
    assert_equal "m/s", @a.lazy.attr(:units)
    assert_equal({ "units" => "m/s" }, @a.lazy.copy.attrs)
  end

  def test_lazy_operation_stops_the_walk
    assert_nil((@a.lazy + 1).attr(:units))
    assert_nil((@a.lazy + @b).attr(:units))
    assert_nil((@b.lazy + @a).attr(:units))
    assert_nil(@a.lazy.sqrt.attr(:units))
    assert_nil((@a.lazy > 1).attr(:units))
    assert_equal({}, (@a.lazy + 1).copy.attrs)
  end

  def test_lazy_and_eager_agree
    assert_equal (@a + 1).attrs, (@a.lazy + 1).attrs
  end

  def test_arithmetic_and_reduction_do_not_carry
    assert_equal({}, (@a + 1).attrs)
    assert_equal({}, @a.sum(axis: 0).attrs)
  end

end
