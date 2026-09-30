# spec_ai/test_scratch_raise_cleanup.rb
#
# Methods that move one cell hold it in a scratch buffer of the cell's
# width: `fill`, `[]=`, `elem_store`, `elem_swap`, `elem_copy`.  The value
# is converted, or the index parsed, after the buffer is taken, and either
# can raise.  The buffer is Ruby's temporary (ALLOCV), so a raise does not
# leave it behind.
#
# The cells here are 128 KB wide (fixlen), so a leak shows as 128 KB or more
# per call against a threshold of 4 KB, measured by utils/measure_leak.rb
# (macOS only).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestScratchRaiseCleanup < Test::Unit::TestCase

  WIDTH = 1 << 17

  def bytes_per_call (expr)
    bytes = LeakMeter.bytes_per_call(expr, setup: "a = CArray.fixlen(4, bytes: #{WIDTH})")
    omit "malloc zone statistics unavailable" if bytes.nil?
    bytes
  end

  def assert_frees_scratch (expr)
    grown = bytes_per_call(expr)
    assert_operator grown, :<, 4096,
                    "#{expr}: the malloc zone grew #{grown.round} bytes per call"
  end

  def test_raises
    a = CArray.fixlen(4, bytes: WIDTH)
    assert_raise(TypeError)  { a.fill(3.5) }
    assert_raise(TypeError)  { a[0] = 3.5 }
    assert_raise(TypeError)  { a.elem_store(0, 3.5) }
    assert_raise(IndexError) { a.elem_swap(0, 99) }
    assert_raise(IndexError) { a.elem_copy(0, 99) }
  end

  def test_fill
    assert_frees_scratch "a.fill(3.5)"
  end

  def test_store_index
    assert_frees_scratch "a[0] = 3.5"
  end

  def test_elem_store
    assert_frees_scratch "a.elem_store(0, 3.5)"
  end

  def test_elem_swap
    assert_frees_scratch "a.elem_swap(0, 99)"
  end

  def test_elem_copy
    assert_frees_scratch "a.elem_copy(0, 99)"
  end

end
