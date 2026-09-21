# spec_ai/test_copy_raise_cleanup.rb
#
# `copy` and `strip_mask(fill)` allocate the result before reading the
# source.  When the read raises (a float64 view over an object array with
# a cell that is not a number), the result, which Ruby does not own yet,
# is freed rather than left behind.
#
# The buffer is plain malloc, invisible from Ruby, so it is measured by
# the malloc zone's bytes-in-use: at these sizes the resident size reads
# the heap's own growth rather than the leak.

require "test/unit"
require "carray"

class TestCopyRaiseCleanup < Test::Unit::TestCase

  # Bytes added to the malloc zone per call of `expr`, with `input` bound
  # to a float64 view over an object array holding a cell that is not a
  # number.  Measured in a fresh process (what earlier tests left in this
  # one's heap moves the count) and through Fiddle, because the resident
  # size at these sizes reads the heap's fragmentation rather than the
  # leak: macOS only.
  def bytes_per_call (expr, n, calls)
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    script = <<~RUBY
      require "carray"
      begin
        require "fiddle"
        stats = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      rescue LoadError, Fiddle::DLError
        exit 2
      end
      in_use = -> {
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        stats.call(nil, buf)
        buf[8, 8].unpack1("Q")          # malloc_statistics_t#size_in_use
      }
      o = CArray.object(#{n}) { 1.0 }
      o[5] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64)
      call = -> { (#{expr}) rescue nil }
      50.times { call.() }
      GC.start
      before = in_use.()
      #{calls}.times { call.() }
      GC.start
      puts (in_use.() - before).fdiv(#{calls})
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", script], &:read)
    omit "malloc zone statistics unavailable" if $?.exitstatus == 2
    assert $?.success?, "measuring process failed"
    Float(out)
  end

  def assert_frees_scratch (expr, n: 1 << 14, calls: 200)
    grown = bytes_per_call(expr, n, calls)
    assert_operator grown, :<, 4096,
                    "#{expr}: the malloc zone grew #{grown.round} bytes per call"
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
    assert_frees_scratch("input.copy")
  end

  def test_strip_mask_frees_result_on_raise
    assert_frees_scratch("input.strip_mask(0.0)")
  end

  # A lazy view's to_a materialises through copy.
  def test_lazy_to_a_frees_result_on_raise
    assert_frees_scratch("input.to_a")
  end
end
