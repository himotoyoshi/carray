# spec_ai/test_scratch_raise_cleanup.rb
#
# Methods that move one cell hold it in a scratch buffer of the cell's
# width: `fill`, `[]=`, `elem_store`, `elem_swap`, `elem_copy`.  The value
# is converted, or the index parsed, after the buffer is taken, and either
# can raise.  The buffer is Ruby's temporary (ALLOCV), so a raise does not
# leave it behind.
#
# The cells here are 128 KB wide (fixlen), so a leak shows as 128 KB or more
# per call against a threshold of 4 KB.  The malloc zone's bytes-in-use is
# read in a fresh process through Fiddle, which is macOS only.

require "test/unit"
require "carray"

class TestScratchRaiseCleanup < Test::Unit::TestCase

  WIDTH = 1 << 17

  def bytes_per_call (expr)
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
      a = CArray.fixlen(4, bytes: #{WIDTH})
      call = -> { (#{expr}) rescue nil }
      50.times { call.() }
      GC.start
      before = in_use.()
      200.times { call.() }
      GC.start
      puts (in_use.() - before).fdiv(200)
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", script], &:read)
    omit "measurement unavailable" if $?.exitstatus == 2
    assert $?.success?, "measuring process failed"
    Float(out)
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
