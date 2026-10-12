# spec_ai/test_select_raise_cleanup.rb
#
# `a[sel]` with a boolean selector snapshots the selector before building
# the view.  When reading the selector raises (an int32 array faked as
# boolean, holding a 2), neither the snapshot nor the view struct is left
# behind.
#
# Neither is ever written before the raise, so its pages never become
# resident and the resident size cannot see them.  The malloc zone's
# bytes-in-use can: macOS only, read through Fiddle.

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestSelectRaiseCleanup < Test::Unit::TestCase

  # Growth of the malloc zone's bytes-in-use per call of a[sel]
  # (utils/measure_leak.rb; macOS only).
  def bytes_per_call (masked, n, calls)
    setup = <<~SETUP
      s = CArray.int32(#{n}) { 1 }
      s[5] = 2
      s[0] = UNDEF if #{masked}
      sel = s.fake(CA_BOOLEAN)
      a = CArray.float64(#{n}) { 1.0 }
    SETUP
    bytes = LeakMeter.bytes_per_call("a[sel]", setup: setup, calls: calls, warmup: 100)
    omit "malloc zone statistics unavailable" if bytes.nil?
    bytes
  end

  def test_raising_selector_raises
    s = CArray.int32(6) { 1 }
    s[3] = 2
    assert_raise(RangeError) { CArray.float64(6)[s.fake(CA_BOOLEAN)] }
  end

  # The view struct alone (about 130 bytes a call when it leaks), so the
  # window is long enough to average the measurement's own noise out.
  def test_raising_selector_leaves_nothing
    grown = bytes_per_call(false, 64, 20_000)
    assert_operator grown, :<, 64, "the malloc zone grew #{grown.round} bytes per call"
  end

  # The snapshot of a masked selector as well: a quarter MB a call, so a
  # threshold far above the noise still catches it.
  def test_masked_raising_selector_leaves_nothing
    grown = bytes_per_call(true, 1 << 18, 500)
    assert_operator grown, :<, 4096, "the malloc zone grew #{grown.round} bytes per call"
  end

  def test_masked_selector_snapshot
    a = CArray.float64(6) { |i| i.to_f }
    s = CArray.boolean(6) { |i| i.odd? ? 1 : 0 }
    s[1] = UNDEF
    v = a[s]
    s[3] = 0
    assert_equal [3.0, 5.0], v.to_a
    assert_equal [3.0, 5.0], v.dup.to_a
  end
end
