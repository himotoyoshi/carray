# spec_ai/test_sweep_engine_raise_cleanup.rb
#
# When the sweep bridge (ca_call_cfunc_* / ca_call_cslab_*) raises part way
# through, it gives back what it took: operands it attached are detached,
# scratch buffers are freed, arena slots are returned.  The raise comes
# from an INPUT whose read converts a value (a float64 view over an object
# array with a cell that is not a number), or from a refused operand
# pairing after the OUTPUT was already attached.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_sweep_raw", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "sweep_raw"
rescue LoadError
  warn "[skip] test_sweep_engine_raise_cleanup.rb: sweep_raw fixture not " \
       "built (run `rake build_author_surface_smoke`)"
  return
end

class TestSweepEngineRaiseCleanup < Test::Unit::TestCase

  RAW = [:__sweep_raw_add__, :__sweep_raw_add_slab__]

  # float64 view whose read raises at cell 5
  def failing_input (n)
    o = CArray.object(n) { 1.0 }
    o[5] = Object.new
    CArray.wrap_readonly(o, CA_FLOAT64)
  end

  # A column of a matrix: an OUTPUT the engine has to attach into a
  # buffer of its own (it does not alias the parent).
  def column_output
    big = CArray.float64(8, 8) { 0.0 }
    [big, big[nil, 1]]
  end

  def good (n)
    CArray.float64(n) { |i| i + 1.0 }
  end

  def test_failing_input_detaches_output
    RAW.each do |m|
      big, out = column_output
      assert_raise(TypeError, m.to_s) { CArray.send(m, out, good(8), failing_input(8)) }
      assert_equal false, out.attached?, m.to_s
      assert_equal [0.0] * 64, big.to_a.flatten, m.to_s
    end
  end

  def test_refused_pairing_detaches_output
    RAW.each do |m|
      _, out = column_output
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, good(8), good(9)) }
      assert_equal false, out.attached?, m.to_s
    end
  end

  def test_output_usable_after_failure
    RAW.each do |m|
      big, out = column_output
      assert_raise(TypeError) { CArray.send(m, out, good(8), failing_input(8)) }
      CArray.send(m, out, good(8), good(8))
      assert_equal good(8).to_a.map { |v| v * 2 }, big[nil, 1].to_a, m.to_s
    end
  end

  # The callback itself raises (a negative input).  The INPUT here converts
  # from int32, so it is read into scratch rather than aliased.
  CHECKED = [:__sweep_raw_add_checked__, :__sweep_raw_add_slab_checked__]

  def negative_input (n)
    CArray.wrap_readonly(CArray.int32(n) { |i| i == 5 ? -1 : i }, CA_FLOAT64)
  end

  def test_raising_callback_detaches_output
    CHECKED.each do |m|
      big, out = column_output
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, negative_input(8), good(8)) }
      assert_equal false, out.attached?, m.to_s
    end
  end

  def test_raising_callback_returns_arena_slots
    before = CArray.__lazy_arena_slot_in_use_count__
    5.times do
      _, out = column_output
      assert_raise(ArgumentError) {
        CArray.__sweep_raw_add_slab_checked__(out, negative_input(8), good(8))
      }
    end
    assert_equal before, CArray.__lazy_arena_slot_in_use_count__
  end

  def test_checked_callback_without_raise
    CHECKED.each do |m|
      big, out = column_output
      CArray.send(m, out, good(8), good(8))
      assert_equal good(8).to_a.map { |v| v * 2 }, big[nil, 1].to_a, m.to_s
    end
  end

  def test_chunked_failure_returns_arena_slots
    before = CArray.__lazy_arena_slot_in_use_count__
    5.times do
      _, out = column_output
      assert_raise(TypeError) {
        CArray.__sweep_raw_add_slab__(out, good(8), failing_input(8))
      }
    end
    assert_equal before, CArray.__lazy_arena_slot_in_use_count__
  end

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

  # The whole-buffer path's scratch copy of a converted INPUT (128 KB
  # here) is freed when the conversion raises.
  def test_failing_input_frees_scratch
    assert_frees_scratch("CAMath.lgamma(input)")
  end
end
