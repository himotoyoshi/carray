# spec_ai/test_attach_raise_cleanup.rb
#
# A view that converts on attach (here an int32 array faked as boolean,
# holding a 2) raises when the conversion meets a value it cannot hold.
# After that raise the view is not attached: the next read converts again
# and raises again, rather than reading the half-converted buffer the
# first attempt left behind.

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestAttachRaiseCleanup < Test::Unit::TestCase

  def faked
    s = CArray.int32(6) { |i| i % 2 }
    s[3] = 2
    [s, s.fake(CA_BOOLEAN)]
  end

  def test_not_attached_after_failed_attach
    _, f = faked
    assert_raise(RuntimeError) { f.to_a }
    assert_equal false, f.attached?
  end

  def test_second_read_raises_again
    _, f = faked
    2.times { assert_raise(RuntimeError) { f.to_a } }
  end

  def test_reads_current_parent_once_fixed
    s, f = faked
    assert_raise(RuntimeError) { f.to_a }
    s[3] = 1
    assert_equal [false, true, false, true, false, true], f.to_a
  end

  def test_parent_not_left_attached
    big = CArray.int32(4, 6) { |i, j| j % 2 }
    big[0, 3] = 2
    s = big[0, nil]
    f = s.fake(CA_BOOLEAN)
    assert_raise(RuntimeError) { f.to_a }
    assert_equal false, s.attached?
  end

  # A masked selector is read by attaching it.
  def test_masked_selector_raises_every_time
    s, f = faked
    s[0] = UNDEF
    a = CArray.float64(6) { |i| i.to_f }
    2.times { assert_raise(RuntimeError) { a[f] } }
  end

  # Views over several parents attach every parent first; when one of
  # those attaches raises, the ones before it are detached again.
  def test_stack_detaches_parents_on_raise
    col = CArray.int32(4, 6) { |i, j| j % 2 }[nil, 1]
    bad = CArray.int32(4) { 2 }.fake(CA_BOOLEAN)
    st = CArray.stack([col.fake(CA_BOOLEAN), bad])
    assert_raise(RuntimeError) { st.to_a }
    assert_equal false, col.attached?
    assert_equal false, st.attached?
  end

  def test_meld_detaches_parents_on_raise
    col = CArray.int32(4, 6) { |i, j| j % 2 }[nil, 1]
    bad = CArray.int32(4) { 2 }.fake(CA_BOOLEAN)
    m = CArray.meld(col.fake(CA_BOOLEAN), bad)
    assert_raise(RuntimeError) { m.to_a }
    assert_equal false, col.attached?
    assert_equal false, m.attached?
  end

  # Bytes the malloc zone grows by per call of `expr`, with `input` bound
  # to a float64 view over an object array holding a cell that is not a
  # number (utils/measure_leak.rb; macOS only).
  def bytes_per_call (expr, n, calls)
    setup = <<~SETUP
      o = CArray.object(#{n}) { 1.0 }
      o[5] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64).reshape(128, 128)
    SETUP
    bytes = LeakMeter.bytes_per_call(expr, setup: setup, calls: calls)
    omit "malloc zone statistics unavailable" if bytes.nil?
    bytes
  end

  def assert_frees_scratch (expr, n: 1 << 14, calls: 200)
    grown = bytes_per_call(expr, n, calls)
    assert_operator grown, :<, 4096,
                    "#{expr}: the malloc zone grew #{grown.round} bytes per call"
  end

  # A reshape of a lazy view gathers into a buffer of its own (there is
  # no parent memory to alias).  When the gather raises, that buffer is
  # freed.
  def test_cold_root_reshape_frees_buffer_on_raise
    assert_frees_scratch("input.to_a")
  end
end
