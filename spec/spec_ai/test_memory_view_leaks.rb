# spec_ai/test_memory_view_leaks.rb
#
# MemoryView export and wrap leave nothing behind:
#
# - a CScalar is exported with ndim 0, so no shape / strides are taken
#   (they used to be allocated and never freed, on every export);
# - a frozen fixlen array is exported like any other (the format String
#   used to be stored on the array, which a frozen one refuses);
# - wrap_memory_view frees its holder when the source is rejected.
#
# Each leak was 32 to 136 bytes per call; the threshold is 16 over 20000
# calls, measured by utils/measure_leak.rb (macOS only).

require "test/unit"
require "carray"
require "fiddle"
require_relative "../../utils/measure_leak"

class TestMemoryViewLeaks < Test::Unit::TestCase

  def assert_leaves_nothing (expr, setup)
    bytes = LeakMeter.bytes_per_call(expr, setup: %{require "fiddle"; } + setup, calls: 20000)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 16,
                    "#{expr}: the malloc zone grew #{bytes.round(1)} bytes per call"
  end

  def test_cscalar_export
    s = CScalar.new(CA_FLOAT64)
    s[0] = 2.5
    m = Fiddle::MemoryView.new(s)
    assert_equal 0, m.ndim
    assert_equal "d", m.format
    assert_equal 8, m.byte_size
    m.release
    assert_leaves_nothing "Fiddle::MemoryView.new(s).release", "s = CScalar.new(CA_FLOAT64)"
  end

  def test_frozen_fixlen_export
    a = CArray.fixlen(3, bytes: 4) { "ab" }.freeze
    m = Fiddle::MemoryView.new(a)
    assert_equal "4s", m.format
    assert_equal 12, m.byte_size
    assert m.readonly?
    m.release
    assert_equal "4s", CArray.__memory_view_format__(a) if CArray.respond_to?(:__memory_view_format__)
    assert_leaves_nothing "Fiddle::MemoryView.new(a).release",
                          "a = CArray.fixlen(*[1]*8, bytes: 4).freeze"
  end

  def test_wrap_of_a_rejected_source
    assert_raise(ArgumentError) { CArray.wrap_memory_view(Object.new) }
    assert_leaves_nothing "CArray.wrap_memory_view(Object.new)", "s = nil"
  end

end
