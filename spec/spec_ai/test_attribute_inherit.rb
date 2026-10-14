require "test/unit"
require "carray"
require "stringio"

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

  def test_a_view_of_a_face_shows_the_faces_attributes
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"])
    t.set_attr(:units, "days")
    assert_equal "days", t[0..1].attr(:units)
    assert_equal "days", t[0..1][0..0].attr(:units)
    assert_equal "days", t.reshape(3, 1).attr(:units)
    assert_equal "days", t[CA_BOOLEAN([1, 0, 1])].attr(:units)
    assert_equal "days", t[0..1].copy.attr(:units)
    t.parent.set_attr(:source, "x")
    assert_equal "x", t[0..1].attr(:source)
    s = CArray.string(CA_OBJECT(%w[a b]))
    s.set_attr(:units, "m")
    assert_equal "m", s[0..0].attr(:units)
    c = CArray.const_string(%w[a b])
    c.set_attr(:units, "m")
    assert_equal "m", c[0..0].attr(:units)
    assert_equal "m", c.copy.attr(:units)
  end

  def test_dup_and_clone_have_their_own_attributes
    a = CArray.int32(2)
    a.set_attr(:units, "m")
    b = a.dup
    b.set_attr(:units, "s")
    c = a.clone
    c.set_attr(:units, "t")
    assert_equal ["m", "s", "t"], [a, b, c].map { |x| x.attr(:units) }
    v = a[0..1]
    v.dup.set_attr(:extra, 1)
    assert_equal({ "units" => "m" }, v.attrs)
  end

  def test_marshal_keeps_attributes
    a = CArray.int32(2).tap { |x| x.set_attr(:units, "m") }
    o = CA_OBJECT([1, 2]).tap { |x| x.set_attr(:units, "m") }
    [a, a[0..1], o, o[0..1]].each do |x|
      assert_equal({ "units" => "m" }, Marshal.load(Marshal.dump(x)).attrs)
    end
  end

  def test_copies_of_values_keep_attributes
    a = CA_INT32([3, 1, 2]).tap { |x| x.set_attr(:units, "m") }
    m = a.copy
    m[0] = UNDEF
    shown = { "units" => "m" }
    [a.sort_copy, m.sort_copy, a.partition_copy(1), m.partition_copy(1),
     a.project(CA_INT64([1, 0])), m.strip_mask(0),
     m.strip_mask(method: :forward), m.strip_mask(method: :backward),
     m.strip_mask(method: :linear)].each do |x|
      assert_equal shown, x.attrs
    end
  end

  def test_stored_values_are_frozen_copies
    a = CArray.int32(2)
    s = +"m"
    a.set_attr(:units, s)
    s << "!"
    assert_equal "m", a.attr(:units)
    a.set_attr(:h, { "k" => [1] })
    assert_raise(FrozenError) { a.copy.attr(:h)["k"] << 2 }
    assert_raise(FrozenError) { a.attrs["units"] << "x" }
    assert_equal({ "k" => [1] }, a.attr(:h))
  end

  def test_a_frozen_array_takes_no_attribute
    a = CA_INT32([1]).tap { |x| x.set_attr(:units, "m") }
    a.freeze
    assert_raise(FrozenError) { a.set_attr(:units, "s") }
    assert_raise(FrozenError) { CA_INT32([1]).freeze.set_attrs(units: "s") }
    assert_equal "m", a.attr(:units)
  end

  def test_a_long_view_chain_keeps_attributes
    a = CA_INT32([1, 2]).tap { |x| x.set_attr(:units, "m") }
    v = a
    100.times { v = v.reshape(2) }
    assert_equal "m", v.attr(:units)
    assert_equal "m", v.copy.attr(:units)
  end

  def test_frame_text_cast_and_outer_join_keep_attributes
    df = CAFrame.from_csv(StringIO.new("a,b\nK,m\n1,x\n2,y\n"), attrs: [:units])
    assert_equal "m", df.head(1)["b"].attr(:units)
    assert_equal "K", df.cast(:infer)["a"].attr(:units)
    assert_equal "K", df.cast("a" => :float64)["a"].attr(:units)
    key = ->(v) { CA_INT32(v).tap { |x| x.set_attr(:units, "k") } }
    l = CAFrame.new("k" => key.([1, 2]), "v" => CA_INT32([1, 2]))
    r = CAFrame.new("k" => key.([2, 3]), "w" => CA_INT32([5, 6]).tap { |x| x.set_attr(:units, "w") })
    j = l.join(r, on: "k", how: :outer)
    assert_equal "k", j["k"].attr(:units)
    assert_equal "w", l.join(r, on: "k")["w"].attr(:units)
  end

  def test_frame_meld_and_concatenate_agree
    f = CAFrame.new("t" => CA_FLOAT64([1, 2]).tap { |c| c.set_attr(:units, "K") })
    g = CAFrame.new("t" => CA_FLOAT64([3]).tap { |c| c.set_attr(:units, "K") })
    assert_equal({ "units" => "K" }, CAFrame.meld(f, g)["t"].attrs)
    assert_equal({ "units" => "K" }, CAFrame.concatenate(f, g)["t"].attrs)
  end

end
