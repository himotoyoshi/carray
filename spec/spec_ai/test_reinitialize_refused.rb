# spec_ai/test_reinitialize_refused.rb
#
# `initialize` and `initialize_copy` set up a freshly allocated array.
# Calling either again on an array that is already set up (through `send`)
# is refused with TypeError: setting it up again would overwrite the buffer
# and the shape arrays it owns without freeing them (524 KB per call for a
# 64 K float64).  `dup`, `clone` and `new` are unaffected.
#
# Also here: CArray.__register_axis_group_classes__ adds its GC roots once,
# not on every call (32 bytes per call before).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestReinitializeRefused < Test::Unit::TestCase

  def assert_refused (&block)
    e = assert_raise(TypeError, &block)
    assert_equal "already initialized array", e.message
  end

  def test_entity
    a = CArray.float64(8).seq!
    assert_refused { a.send(:initialize, :float64, [8]) }
    assert_refused { a.send(:initialize_copy, CArray.float64(8)) }
    assert_equal (0...8).map(&:to_f), a.to_a
  end

  def test_scalar
    s = CScalar.new(:float64)
    assert_refused { s.send(:initialize, :float64) }
    assert_refused { s.send(:initialize_copy, CScalar.new(:float64)) }
  end

  def test_stack_and_meld
    ps = [CArray.int32(3), CArray.int32(3)]
    st = CArray.stack(ps)
    assert_refused { st.send(:initialize, ps) }
    assert_refused { st.send(:initialize_copy, CArray.stack(ps)) }
    ml = CArray.meld(ps)
    assert_refused { ml.send(:initialize, ps) }
    assert_refused { ml.send(:initialize_copy, CArray.meld(ps)) }
  end

  def test_caobject
    klass = Class.new(CAObject) do
      def initialize (n) ; super(CA_FLOAT64, [n]) ; end
      def fetch_addr (addr) ; addr.to_f ; end
    end
    o = klass.new(4)
    assert_refused { o.send(:initialize, 4) }
    assert_equal [0.0, 1.0, 2.0, 3.0], o.to_a
  end

  def test_views
    a = CArray.int32(4, 4).seq!
    i = CA_INT64([0, 2])
    views = [
      a[0..1, nil], a.transpose, a.reshape(16), a[a > 5], a[i, nil],
      a.flatten[i], a.shift(1, 0), a.window(0..1, 0..1), a.tile(2, 1),
      a.roll(1, 0), a.fake(:float64), a.bits, a.bitfield(0, 3),
      a.swap_bytes, a.lazy, a.lazy + 1, a.lazy > 1, -a.lazy,
      a[2, :%, :%],
    ].compact
    views.each do |v|
      assert_refused { v.send(:initialize_copy, v.dup) }
      assert_equal v.dup.to_a, v.to_a, v.class.to_s
    end
  end

  def test_dup_and_clone_still_work
    a = CArray.int32(4).seq!
    assert_equal a.to_a, a.dup.to_a
    assert_equal a.to_a, a.clone.to_a
    v = a[1..2]
    assert_equal [1, 2], v.dup.to_a
    assert_equal [1, 2], v.clone.to_a
  end

  def test_axis_group_class_registration_adds_no_root
    bytes = LeakMeter.bytes_per_call(
      "CArray.__register_axis_group_classes__(CACategorical, AxisGroup)",
      setup: "CACategorical ; AxisGroup", calls: 20000)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 8
  end

end
