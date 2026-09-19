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

  # The whole-buffer path's scratch copy of a converted INPUT is plain
  # malloc, invisible from Ruby, so it is measured by the resident size, in
  # a fresh process (what earlier tests left in this one's heap changes how
  # the pages count).  The heap grows over the first thousand or so calls
  # whether or not anything leaks, so the measurement starts after that: a
  # leak keeps growing it by about 0.3 MB per call, a sound path levels off.
  def test_failing_input_frees_scratch
    script = <<~RUBY
      require "carray"
      rss = -> { Integer(`ps -o rss= -p \#{Process.pid}`.strip, exception: false) }
      exit 2 unless rss.()
      o = CArray.object(1 << 16) { 1.0 }
      o[5] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64)
      call = -> { CAMath.lgamma(input) rescue nil }
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
    grown_mb = Float(out)
    assert_operator grown_mb, :<, 100, "resident size grew #{grown_mb.round} MB over 1000 calls"
  end
end
