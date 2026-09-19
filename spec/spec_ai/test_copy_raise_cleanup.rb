# spec_ai/test_copy_raise_cleanup.rb
#
# `copy` and `strip_mask(fill)` allocate the result before reading the
# source.  When the read raises (a float64 view over an object array with
# a cell that is not a number), the result, which Ruby does not own yet,
# is freed rather than left behind.
#
# The buffer is plain malloc, invisible from Ruby, so it is measured by
# the resident size.  The heap grows over the first thousand or so calls
# whether or not anything leaks, so the measurement starts after that: a
# leak keeps growing it by a quarter MB or more per call, a sound path
# levels off.

require "test/unit"
require "carray"

class TestCopyRaiseCleanup < Test::Unit::TestCase

  # Resident-size growth, in MB, over the second 1000 of 2500 calls of
  # `expr` (with `input` bound to a float64 view over an object array that
  # holds a cell that is not a number).  Measured in a fresh process: what
  # earlier tests left in this one's heap changes how the pages count.
  def growth_mb (expr)
    script = <<~RUBY
      require "carray"
      rss = -> { Integer(`ps -o rss= -p \#{Process.pid}`.strip, exception: false) }
      exit 2 unless rss.()
      o = CArray.object(1 << 16) { 1.0 }
      o[5] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64)
      call = -> { (#{expr}) rescue nil }
      1500.times { call.() }
      GC.start
      r0 = rss.()
      1000.times { call.() }
      GC.start
      puts (rss.() - r0) / 1024.0
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", script], &:read)
    omit "ps unavailable" if $?.exitstatus == 2
    assert $?.success?, "measuring process failed"
    Float(out)
  end

  def assert_levels_off (expr)
    grown = growth_mb(expr)
    assert_operator grown, :<, 100,
                    "#{expr}: resident size grew #{grown.round} MB over 1000 calls"
  end

  def failing_input
    o = CArray.object(8) { 1.0 }
    o[5] = Object.new
    CArray.wrap_readonly(o, CA_FLOAT64)
  end

  def test_copy_raises
    assert_raise(TypeError) { failing_input.copy }
  end

  def test_strip_mask_raises
    assert_raise(TypeError) { failing_input.strip_mask(0.0) }
  end

  def test_copy_frees_result_on_raise
    assert_levels_off("input.copy")
  end

  def test_strip_mask_frees_result_on_raise
    assert_levels_off("input.strip_mask(0.0)")
  end

  # A lazy view's to_a materialises through copy.
  def test_lazy_to_a_frees_result_on_raise
    assert_levels_off("input.to_a")
  end
end
