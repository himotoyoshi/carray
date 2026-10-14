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

  def test_set_attrs_copies_what_another_array_shows
    v = @a[0, nil]
    v.set_attr(:slice, "row0")
    c = CArray.int32(4)
    assert_same c, c.set_attrs(v.attrs)
    assert_equal({ "slice" => "row0", "units" => "m/s" }, c.attrs)
    c.set_attr(:units, "K")
    assert_equal "m/s", @a.attr(:units)
  end

  def test_set_attrs_merges_into_own_keys
    @b.set_attr(:scale, 2)
    @b.set_attrs(units: "m/s", tag: :x)
    assert_equal({ "scale" => 2, "units" => "m/s", "tag" => "x" }, @b.attrs)
  end

  def test_set_attrs_rejects_before_writing
    assert_raise(TypeError) { @b.set_attrs("tag" => "ok", "bad" => Object.new) }
    assert_equal({ "units" => "K" }, @b.attrs)
    assert_raise(TypeError) { @b.set_attrs([[:units, "m/s"]]) }
  end

  def test_lazy_type_conversion_walks_through
    i = CA_INT32([1, 2])
    i.set_attr(:units, "m/s")
    assert_equal "m/s", CArray.wrap_readonly(i, CA_FLOAT64).attr(:units)
  end

  def test_joined_arrays_show_the_keys_they_agree_on
    x = CA_FLOAT64([1, 2]).tap { |c| c.set_attrs(units: "m/s", src: "x") }
    y = CA_FLOAT64([3, 4]).tap { |c| c.set_attrs(units: "m/s", src: "y") }
    shared = { "units" => "m/s" }
    assert_equal shared, CArray.stack([x, y]).attrs
    assert_equal shared, CArray.meld([x, y]).attrs
    assert_equal shared, CArray.montage([x, y], [2]).attrs
    assert_equal shared, CArray.concatenate([x, y]).attrs
    assert_equal shared, CArray.meld([x, y]).copy.attrs
  end

  def test_joined_arrays_drop_a_key_they_disagree_on_or_lack
    x = CA_FLOAT64([1, 2]).tap { |c| c.set_attr(:units, "m/s") }
    y = CA_FLOAT64([3, 4]).tap { |c| c.set_attr(:units, "K") }
    z = CA_FLOAT64([5, 6])
    assert_equal({}, CArray.stack([x, y]).attrs)
    assert_equal({}, CArray.meld([x, z]).attrs)
    assert_equal({}, CArray.concatenate([x, y]).attrs)
    assert_equal({}, CArray.concatenate([x, z]).attrs)
  end

  def test_joined_arrays_of_different_types_agree
    x = CA_FLOAT64([1, 2]).tap { |c| c.set_attr(:units, "m/s") }
    i = CA_INT32([3, 4]).tap { |c| c.set_attr(:units, "m/s") }
    assert_equal({ "units" => "m/s" }, CArray.stack([x, i]).attrs)
    assert_equal({ "units" => "m/s" }, CArray.concatenate([x, i]).attrs)
  end

  def test_a_joined_view_keeps_its_own_keys_first
    x = CA_FLOAT64([1, 2]).tap { |c| c.set_attr(:units, "m/s") }
    y = CA_FLOAT64([3, 4]).tap { |c| c.set_attr(:units, "m/s") }
    m = CArray.meld([x, y])
    m.set_attr(:units, "K")
    assert_equal "K", m.attr(:units)
    assert_equal "m/s", x.attr(:units)
  end

  def test_frame_meld_and_concatenate_agree
    f = CAFrame.new("t" => CA_FLOAT64([1, 2]).tap { |c| c.set_attr(:units, "K") })
    g = CAFrame.new("t" => CA_FLOAT64([3]).tap { |c| c.set_attr(:units, "K") })
    assert_equal({ "units" => "K" }, CAFrame.meld(f, g)["t"].attrs)
    assert_equal({ "units" => "K" }, CAFrame.concatenate(f, g)["t"].attrs)
  end

end
