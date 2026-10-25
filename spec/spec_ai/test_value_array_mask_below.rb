# A view somewhere below a value array (x.value) has no mask: it reads the
# raw values, refuses UNDEF, and leaves the masked root as it was.  The
# answer comes from asking up the chain until the marked value array is
# reached, so every kind of level in between is exercised here, and the one
# level that answers without asking its parent (a CAObject with its own
# mask hook).

require "test/unit"
require "carray"

class TestValueArrayMaskBelow < Test::Unit::TestCase

  def masked_x
    x = CArray.int32(6).seq
    x[1] = UNDEF
    x
  end

  VIEWS = {
    "refer"              => ->(v) { v.refer },
    "refer.refer"        => ->(v) { v.refer.refer },
    "block"              => ->(v) { v[1..4] },
    "block of block"     => ->(v) { v[1..4][0..2] },
    "reshape"            => ->(v) { v.reshape(2, 3) },
    "reshape transpose"  => ->(v) { v.reshape(2, 3).transpose },
    "reshape column"     => ->(v) { v.reshape(2, 3)[nil, 1] },
    "grid"               => ->(v) { v[CA_INT64([0, 1, 4])] },
    "block of grid"      => ->(v) { v[CA_INT64([0, 1, 4])][0..1] },
    "select"             => ->(v) { v[v < 3] },
    "shift"              => ->(v) { v.shift(1) },
    "block of shift"     => ->(v) { v.shift(1)[0..2] },
    "roll"               => ->(v) { v.roll(1) },
    "window"             => ->(v) { v.window(-1..6) },
    "block of window"    => ->(v) { v.window(-1..6)[0..2] },
    "tile"               => ->(v) { v.tile(2) },
    "fake"               => ->(v) { v.fake(:float64) },
    "block of fake"      => ->(v) { v.fake(:float64)[0..2] },
    "swap_bytes"         => ->(v) { v.swap_bytes },
    "bitarray"           => ->(v) { v.bitarray[0..63] },
    "lazy"               => ->(v) { v.lazy + 1 },
    "block of lazy"      => ->(v) { (v.lazy + 1)[0..2] },
  }

  VIEWS.each do |name, build|
    define_method("test_#{name.tr(' ', '_')}_has_no_mask") do
      x = masked_x
      a = build.call(x.value)
      assert_equal false, a.has_mask?, name
      assert_equal false, a.any_masked?, name
      assert_equal 0, a.count_masked, name
      assert_not_include a.to_a.flatten, UNDEF, name
      assert_equal [0, UNDEF, 2, 3, 4, 5], x.to_a, name
    end
  end

  def test_undef_written_below_is_refused
    x = masked_x
    [x.value.refer, x.value[1..4][0..2], x.value.shift(1)[0..2]].each do |a|
      assert_raise(TypeError) { a[0] = UNDEF }
    end
    assert_equal [0, UNDEF, 2, 3, 4, 5], x.to_a
  end

  def test_values_read_through_the_chain
    x = masked_x
    assert_equal [1, 2, 3], x.value[1..4][0..2].to_a
    assert_equal 1,         x.value.refer.refer[1]
    assert_equal [[0, 1, 2], [3, 4, 5]], x.value.reshape(2, 3).to_a
  end

  # The root gets its mask after the views below its value array exist.
  def test_root_masked_after_the_views
    x  = CArray.int32(6).seq
    v  = x.value
    bb = v[1..4][0..2]
    r  = v.refer.refer
    x[2] = UNDEF
    assert_equal false, bb.has_mask?
    assert_equal [1, 2, 3], bb.to_a
    assert_equal false, r.has_mask?
    assert_equal [0, 1, 2, 3, 4, 5], r.to_a
  end

  # The value of a masked view, then a view of that value.
  def test_value_of_a_masked_view
    y = CArray.int32(6).seq
    y[0] = UNDEF
    w = y[0..3]
    assert_equal true, w.has_mask?
    a = w.value[0..2]
    assert_equal false, a.has_mask?
    assert_equal [0, 1, 2], a.to_a
    assert_equal true, w.has_mask?
  end

  # A multi-parent view gets its mask from the parent that has one only.
  def test_stack_and_meld_with_a_value_array
    x = masked_x
    s = CArray.stack([x.value, x])
    assert_equal true, s.has_mask?
    assert_equal [false] * 6 + [false, true, false, false, false, false],
                 s.is_masked.to_a.flatten
    m = CArray.meld(x.value, x)
    assert_equal [0, 1, 2, 3, 4, 5, 0, UNDEF, 2, 3, 4, 5], m.to_a
    assert_equal false, CArray.stack([x.value, x.value]).has_mask?
    assert_equal false, CArray.meld(x.value, x.value)[2..5].has_mask?
  end

  def test_face_value_views
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"])
    t[1] = UNDEF
    a = t.value[0..1].refer
    assert_equal false, a.has_mask?
    assert_kind_of CATime::Element, a[1]
    assert_equal false, t.value[0..2][0..1].has_mask?
    assert_raise(TypeError) { t.value[0..2][1] = UNDEF }
    assert_equal true, t.has_mask?
  end

  # A CAObject answers from its own hook rather than asking its parent, so
  # it is the one level that has to look for a value array above itself.
  class HookedMask < CAObject
    def initialize (par)
      @src = par
      super(par.data_type, par.shape, parent: par)
    end
    def mask_created?; true; end
    def create_mask; end
    def copy_data (d); d[] = @src.value; end
    def fetch_addr (a); @src.value[a]; end
    def mask_fetch_addr (a); 0; end
  end

  def test_caobject_with_mask_hook_below_a_value_array
    x = CArray.float64(6).seq
    x[1] = UNDEF
    [x.value, x.value[0..5]].each do |par|
      o = HookedMask.new(par)
      assert_equal true,  o.value_array?
      assert_equal false, o.has_mask?
      assert_equal false, o[0..2].has_mask?
      assert_equal [0.0, 1.0, 2.0], o[0..2].to_a
    end
    assert_equal true, HookedMask.new(x).has_mask?
  end

end
