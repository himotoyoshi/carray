# PROPOSAL_CAFACE F.S0 — Face state homogeneity check
#
# Prerequisite for next-phase multi-Face APIs (= CAStack Face lift).
# Tests `CArray#face_state_compatible?(other)` dispatch:
#   1. C hook (CATime / CATimedelta) → struct-tail compare
#   2. Ruby method override on subclass → invoke via reflection
#   3. Default → true (no C hook, no Ruby override)

require 'test/unit'
require 'carray'

class TestCAFacePhase5 < Test::Unit::TestCase

  # ---- AC1: CATime unit match / mismatch ----

  def test_datetime_same_unit_compatible
    a = CArray.int64(3).time(unit: :ns)
    b = CArray.int64(3).time(unit: :ns)
    assert_equal true,  a.face_state_compatible?(b)
    assert_equal true,  b.face_state_compatible?(a)
  end

  def test_datetime_different_unit_incompatible
    a = CArray.int64(3).time(unit: :ns)
    b = CArray.int64(3).time(unit: :s)
    assert_equal false, a.face_state_compatible?(b)
    assert_equal false, b.face_state_compatible?(a)
  end

  def test_datetime_various_units
    [:ns, :us, :ms, :s, :m, :h, :D].each do |u1|
      [:ns, :us, :ms, :s, :m, :h, :D].each do |u2|
        a = CArray.int64(2).time(unit: u1)
        b = CArray.int64(2).time(unit: u2)
        expected = (u1 == u2)
        assert_equal expected, a.face_state_compatible?(b),
                     "#{u1} vs #{u2}"
      end
    end
  end

  # ---- AC1: CATimedelta unit match / mismatch ----

  def test_timedelta_same_unit_compatible
    a = CArray.int64(3).timedelta(unit: :ns)
    b = CArray.int64(3).timedelta(unit: :ns)
    assert_equal true,  a.face_state_compatible?(b)
  end

  def test_timedelta_different_unit_incompatible
    a = CArray.int64(3).timedelta(unit: :ns)
    b = CArray.int64(3).timedelta(unit: :us)
    assert_equal false, a.face_state_compatible?(b)
  end

  # ---- AC1: class mismatch → ArgumentError ----

  def test_class_mismatch_raises
    a = CArray.int64(3).time(unit: :ns)
    b = CArray.int64(3).timedelta(unit: :ns)
    assert_raise(ArgumentError) { a.face_state_compatible?(b) }
    assert_raise(ArgumentError) { b.face_state_compatible?(a) }
  end

  # ---- AC1: non-Face arg → ArgumentError ----

  def test_non_face_receiver_raises
    a = CArray.int64(3)                            # plain CArray
    b = CArray.int64(3).time(unit: :ns)
    assert_raise(ArgumentError) { a.face_state_compatible?(b) }
  end

  def test_non_face_argument_raises
    a = CArray.int64(3).time(unit: :ns)
    b = CArray.int64(3)                            # plain CArray
    assert_raise(ArgumentError) { a.face_state_compatible?(b) }
  end

  def test_non_carray_argument_raises
    a = CArray.int64(3).time(unit: :ns)
    assert_raise(ArgumentError) { a.face_state_compatible?(42) }
    assert_raise(ArgumentError) { a.face_state_compatible?("foo") }
  end

  # ---- AC2: C hook is consulted before Ruby fallback ----
  # The internal C dispatcher (= ca_face_state_compatible) prefers the
  # registered C hook over the Ruby method path. CATime has a hook,
  # so its result reflects struct-tail (= unit) comparison, NOT any Ruby
  # method that might happen to exist on the class. (A user-level Ruby
  # `def face_state_compatible?` would shadow the CArray-defined entry
  # point itself by normal Ruby dispatch, so the meaningful precedence
  # is at the internal-dispatcher level — observed via the entry point
  # below when no override shadows it.)
  def test_c_hook_drives_result_for_registered_face
    a = CArray.int64(2).time(unit: :ns)
    b = CArray.int64(2).time(unit: :ns)
    c = CArray.int64(2).time(unit: :us)
    # Hook returns 1 iff units match — drives both directions.
    assert_equal true,  a.face_state_compatible?(b)
    assert_equal false, a.face_state_compatible?(c)
  end

  # ---- AC3: Ruby method path for Face subclass without C hook ----

  def test_ruby_method_path_via_test_fixture
    # Define a Ruby-only Face subclass (= CAObject + face: true) with a
    # `face_state_compatible?` instance method. The C hook table has no
    # entry for this obj_type, so dispatch should fall through to the Ruby
    # method.
    klass = Class.new(CAObject) do
      def initialize(parent, tag:)
        @tag = tag
        super(CA_FLOAT64, parent.dim, parent: parent, face: true)
      end
      attr_reader :tag
      def copy_state(src); @tag = src.tag; end
      def face_state_compatible?(other)
        @tag == other.tag
      end
    end
    p1 = CArray.float64(3) { 0.0 }
    p2 = CArray.float64(3) { 0.0 }
    a = klass.new(p1, tag: :alpha)
    b = klass.new(p2, tag: :alpha)
    c = klass.new(p2, tag: :beta)
    assert_equal true,  a.face_state_compatible?(b)
    assert_equal false, a.face_state_compatible?(c)
  end

  # ---- AC4: default compatible (no hook, no override) ----

  def test_default_compatible_when_no_override
    # Face subclass without face_state_compatible? override and without
    # C hook registration → default true.
    klass = Class.new(CAObject) do
      def initialize(parent)
        super(CA_FLOAT64, parent.dim, parent: parent, face: true)
      end
    end
    p1 = CArray.float64(3) { 0.0 }
    p2 = CArray.float64(3) { 0.0 }
    a = klass.new(p1)
    b = klass.new(p2)
    assert_equal true, a.face_state_compatible?(b)
  end

end
