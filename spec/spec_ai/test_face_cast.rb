# Casting a Face: :object is the surface, everything else is the Face's own
# #to_numeric (devel/PROPOSAL_FACE_OBJECT_SURFACE_CAST.md Phase 1).
#
# A Face exists so that reads do not descend to the storage, so an object cast
# of one holds its element values: labels rather than codes, CATime::Element
# rather than serials, the string rather than the (start, end) descriptor.
# The storage stays reachable, deliberately, through `.parent`.
#
# The same rule was already in force for data_class arrays (CARecord /
# CAStruct); these pin the Face half of it.

require "carray"
require "test/unit"

class TestFaceObjectCast < Test::Unit::TestCase

  def test_time_casts_to_its_elements
    t = CArray.time([0, 1], unit: :s)
    o = t.to_type(:object)
    assert_equal :object, o.data_type
    assert_equal t.to_a, o.to_a
    assert_kind_of CATime::Element, o[0]
  end

  def test_timedelta_casts_to_its_elements
    td = CArray.time([5, 20], unit: :s) - CArray.time([0, 10], unit: :s)
    o = td.to_type(:object)
    assert_equal td.to_a, o.to_a
    assert_kind_of CATimedelta::Element, o[0]
  end

  def test_const_string_casts_to_the_strings_not_the_descriptor
    cs = CArray.const_string(["ab", "cde"])
    assert_equal ["ab", "cde"], cs.to_type(:object).to_a
  end

  def test_categorical_casts_to_labels_not_codes
    cat = CA_OBJECT(["p", "q", "p"]).categorize
    assert_equal ["p", "q", "p"], cat.to_type(:object).to_a
  end

  def test_fixlen_string_casts_to_the_strings
    fs = CArray.fixlen_string(["ab", "cd"], bytes: 2)
    assert_equal ["ab", "cd"], fs.to_type(:object).to_a
  end

  def test_object_alias_takes_the_same_path
    cat = CA_OBJECT(["p", "q"]).categorize
    assert_equal ["p", "q"], cat.object.to_a
  end

  def test_mask_is_carried
    t = CArray.time([0, 1, 2], unit: :s)
    t[1] = UNDEF
    o = t.to_type(:object)
    assert_equal UNDEF, o[1]
    assert_equal t[0], o[0]
  end

  def test_shape_is_carried
    t = CArray.time([[0, 1], [2, 3]], unit: :s)
    o = t.to_type(:object)
    assert_equal [2, 2], o.shape
    assert_equal t[1, 1], o[1, 1]
  end

  def test_scalar_face_casts_to_a_scalar_object
    o = CArray.time([0, 1], unit: :s)[0..0].to_type(:object)
    assert_equal :object, o.data_type
    assert_kind_of CATime::Element, o[0]
  end

  def test_a_plain_fixlen_column_is_unaffected
    # Not a Face: its storage bytes *are* its value, so the cast is unchanged.
    fx = CA_FIXLEN(["ab", "cd"], bytes: 2)
    assert_equal false, fx.face?
    assert_equal ["ab", "cd"], fx.to_type(:object).to_a
  end

  def test_the_storage_stays_reachable_through_parent
    t = CArray.time([0, 1], unit: :s)
    assert_equal [0, 1], t.parent.to_type(:object).to_a
  end

  def test_numeric_targets_refuse_and_name_the_missing_declaration
    # A time is not a number, so CATime declares no #to_numeric; the refusal
    # now comes from that rule (TestFaceNumericCast below) rather than from
    # the cast table, and says what is missing.
    t = CArray.time([0, 1], unit: :s)
    e = assert_raise(TypeError) { t.to_type(:int64) }
    assert_match(/to_numeric/, e.message)
  end

  # --- the same rule in to_a (the fast path used to read the storage) ---

  # A Face with numeric storage: to_a used to take the numeric fast path,
  # which reads the storage buffer and so handed back the storage values
  # while ca[i] / each / to_type(:object) decoded.  No in-core Face is
  # numeric-storage any more (CATimedelta became NonNumeric), so the rule is
  # pinned on a Face defined here -- which is also the shape an out-of-tree
  # Numeric Face takes.
  class Halved < CAObject
    def initialize(parent); super(CA_FLOAT64, parent.dim, parent: parent, face: true); end
    def storage_to_scalar(raw); raw / 2.0; end
  end

  def test_to_a_of_a_numeric_storage_face_decodes
    h = Halved.new(CA_FLOAT64([5.0, 20.0]))
    assert_equal :float64, h.data_type
    assert_equal [2.5, 10.0], h.to_a
    assert_equal h.each.to_a, h.to_a
    assert_equal h.to_type(:object).to_a, h.to_a
  end

  def test_to_a_of_a_plain_numeric_array_is_unchanged
    assert_equal [1.0, 2.0], CA_FLOAT64([1, 2]).to_a
    assert_equal [1, 2], CA_INT32([1, 2]).to_a
    assert_equal [true, false], CA_BOOLEAN([1, 0]).to_a
  end

  def test_a_view_of_a_face_casts_through_the_surface_too
    t = CArray.time([0, 1, 2, 3], unit: :s)
    assert_equal t[1..2].to_a, t[1..2].to_type(:object).to_a
  end
end


# A NonNumeric Face (CA_FIXLEN surface) gates the numeric kernels off, so the
# core cannot read numbers out of it: the storage is scaled integers and only
# the Face knows the scale. #to_numeric is where the Face says how. A Face
# that declares nothing raises rather than handing back storage bytes or an
# array of UNDEF.
class TestFaceNumericCast < Test::Unit::TestCase

  # A minimal fixed-point Face: int64 storage, CA_FIXLEN surface, one scale.
  class ScaledInt < CAObject
    def initialize(parent, scale: 100)
      @scale = scale
      super(CA_FIXLEN, parent.dim, bytes: 8, storage: CA_INT64,
            parent: parent, face: true)
    end
    attr_reader :scale
    def copy_state(src); @scale = src.scale; end
    def storage_to_scalar(raw)
      (raw.is_a?(String) ? raw.unpack1("q") : raw) / @scale.to_f
    end
    def to_numeric; parent.float64 / @scale.to_f; end
  end

  # The same, declaring nothing.
  class Undeclared < ScaledInt
    undef_method :to_numeric
  end

  # A Numeric Face: its surface *is* its storage, so casts need no declaration.
  class Radians < CAObject
    def initialize(parent); super(CA_FLOAT64, parent.dim, parent: parent, face: true); end
  end

  def setup
    @cents = CArray.int64(3) { |i| [12345, 13020, 12875][i] }
  end

  def test_declared_conversion_serves_the_cast
    fp = ScaledInt.new(@cents)
    assert_equal [123.45, 130.20, 128.75], fp.to_type(:float64).to_a
    assert_equal [123.45, 130.20, 128.75], fp.float64.to_a
  end

  def test_the_requested_type_is_an_ordinary_cast_of_the_projection
    # to_numeric returns float64; :int64 is then the ordinary float -> int cast.
    assert_equal [123, 130, 128], ScaledInt.new(@cents).to_type(:int64).to_a
  end

  def test_mask_carries_through_the_projection
    cents = @cents.copy
    cents[1] = UNDEF
    assert_equal UNDEF, ScaledInt.new(cents).to_type(:float64)[1]
  end

  def test_a_face_that_declares_nothing_raises
    e = assert_raise(TypeError) { Undeclared.new(@cents).to_type(:float64) }
    assert_match(/to_numeric/, e.message)
  end

  def test_in_core_faces_declare_nothing_and_so_raise
    # Their values are not numbers; the message names the two explicit routes.
    assert_raise(TypeError) { CArray.time([0, 1], unit: :s).to_type(:fixlen) }
    assert_raise(TypeError) { CA_OBJECT(["p", "q"]).categorize.to_type(:int32) }
    assert_raise(TypeError) { CArray.const_string(["ab"]).to_type(:int32) }
  end

  def test_object_is_still_the_surface_and_needs_no_declaration
    assert_equal ["p", "q"], CA_OBJECT(["p", "q"]).categorize.to_type(:object).to_a
    assert_kind_of Float, Undeclared.new(@cents).to_type(:object)[0]
  end

  def test_a_numeric_face_casts_without_a_declaration
    # surface == storage, so the ordinary cast was already right.
    r = Radians.new(CArray.float64(3) { |i| [0.0, 1.0, 2.0][i] })
    assert_equal [0.0, 1.0, 2.0], r.to_type(:float64).to_a
    assert_equal [0, 1, 2], r.to_type(:int32).to_a
  end

  def test_a_projection_of_the_wrong_kind_is_refused
    klass = Class.new(ScaledInt) { def to_numeric; [1, 2, 3]; end }
    assert_raise(TypeError) { klass.new(@cents).to_type(:float64) }

    klass = Class.new(ScaledInt) { def to_numeric; ScaledInt.new(parent); end }
    assert_raise(TypeError) { klass.new(@cents).to_type(:float64) }

    klass = Class.new(ScaledInt) { def to_numeric; CA_FLOAT64([1.0]); end }
    assert_raise(ArgumentError) { klass.new(@cents).to_type(:float64) }
  end
end


# The view side of the same rule.  as_type / fake / wrap_readonly /
# wrap_writable reinterpret storage under another data_type, and a Face's
# storage is what its surface exists to hide, so none of them may hand it
# back.  wrap_readonly -- which already returns entities for its non-CArray
# inputs -- answers with the eager conversion; as_type, fake and
# wrap_writable have no honest answer and say so.  A Numeric Face is not
# affected: its surface is its storage.
class TestFaceTypeAdaptView < Test::Unit::TestCase

  def setup
    @t = CArray.time([0, 1], unit: :s)
  end

  def test_as_type_refuses_and_names_both_ways_down
    e = assert_raise(TypeError) { @t.as_type(:object) }
    assert_match(/CATime/, e.message)
    assert_match(/to_type/, e.message)
    assert_match(/parent/, e.message)
    assert_raise(TypeError) { @t.as_type(:int64) }
  end

  def test_fake_refuses_and_points_at_the_storage
    e = assert_raise(TypeError) { @t.fake(:object) }
    assert_match(/parent\.fake/, e.message)
  end

  def test_the_storage_stays_reachable_through_parent
    assert_equal [0, 1], @t.parent.fake(:object).to_a
  end

  def test_wrap_readonly_answers_with_the_surface
    o = CArray.wrap_readonly(@t, CA_OBJECT)
    assert_equal :object, o.data_type
    assert_equal @t.to_a, o.to_a
    assert_kind_of CATime::Element, o[0]
  end

  def test_wrap_readonly_to_a_number_asks_the_face_for_one
    e = assert_raise(TypeError) { CArray.wrap_readonly(@t, CA_INT64) }
    assert_match(/to_numeric/, e.message)
  end

  def test_a_declared_conversion_serves_wrap_readonly
    fp = TestFaceNumericCast::ScaledInt.new(CArray.int64(2) { |i| [12345, 13020][i] })
    assert_equal [123.45, 130.20], CArray.wrap_readonly(fp, CA_FLOAT64).to_a
  end

  def test_wrap_writable_refuses_outright
    e = assert_raise(TypeError) { CArray.wrap_writable(@t, CA_OBJECT) }
    assert_match(/writable/, e.message)
  end

  def test_const_string_does_not_leak_its_descriptor
    cs = CArray.const_string(["ab", "cde"])
    assert_raise(TypeError) { cs.fake(:object) }
    assert_equal ["ab", "cde"], CArray.wrap_readonly(cs, CA_OBJECT).to_a
  end

  def test_fixlen_string_gives_the_string_not_the_padding
    fs = CArray.fixlen_string(["ab", "cdef"], bytes: 4)
    assert_equal ["ab", "cdef"], CArray.wrap_readonly(fs, CA_OBJECT).to_a
  end

  # A Face operand of a plain object array used to be coerced by reading its
  # storage bytes, so the comparison silently saw byte strings and answered
  # false.  The eager side had always refused loudly; the two agree now.
  def test_an_object_array_compares_against_the_surface
    o = CA_OBJECT([@t[0], @t[1]])
    assert_equal [true, true], o.eq(@t).to_a
  end

  # A Numeric Face declares its storage as its surface, so an ordinary cast
  # is right and the view stays a view.
  def test_a_numeric_face_still_adapts
    r = TestFaceNumericCast::Radians.new(CA_FLOAT64([1.0, 2.0]))
    assert_equal [1.0, 2.0], r.as_type(:float32).to_a
    assert_equal [1.0, 2.0], CArray.wrap_readonly(r, CA_FLOAT32).to_a
  end

  # Nothing above applies to a plain array: fake and as_type are its
  # documented reinterpret, and they still return views.
  def test_a_plain_array_is_untouched
    a = CA_INT32([1, 2])
    assert_equal [1, 2], a.fake(:object).to_a
    assert_kind_of CAFake, a.fake(:object)
    assert_equal [1.0, 2.0], a.as_type(:float64).to_a
    assert_equal [1.0, 2.0], CArray.wrap_readonly(a, CA_FLOAT64).to_a
    assert_equal [1.0, 2.0], CArray.wrap_writable(a, CA_FLOAT64).to_a
  end
end
