# Measure how much memory one call of a Ruby expression leaves behind.
#
# The expression runs in a fresh process: whatever earlier code left in
# this process's heap would move the number.  After +setup+, the child
# calls the expression +warmup+ times, runs GC, reads the malloc zone's
# bytes in use, calls it +calls+ more times, runs GC again, and reports
# the growth divided by +calls+.  A raise from the expression is rescued,
# since the cases worth measuring are mostly the ones that raise.
#
# The number is read from macOS's malloc_zone_statistics through Fiddle,
# so it counts C allocations (xmalloc, ALLOC_N) that Ruby cannot see.  The
# resident set size is not used: heap fragmentation moves it by more than
# a leak of a few kilobytes per call, and a buffer that is allocated but
# never written does not become resident at all.
#
# Command line:
#
#   ruby -Iext -Ilib utils/measure_leak.rb [options] EXPR
#
#     -s, --setup CODE    run once before measuring (e.g. to build `a`)
#     -n, --calls N       calls measured (default 200)
#     -w, --warmup N      calls before measuring (default 50)
#     -t, --threshold B   exit 1 when a call leaves B bytes or more
#
#   ruby -Iext -Ilib utils/measure_leak.rb \
#     -s 'a = CArray.fixlen(4, bytes: 1 << 17)' 'a.fill(3.5)'
#
# It prints the bytes per call and the carray_ext the child loaded; check
# the latter, since a build missing from the load path silently falls back
# to an installed gem.  Exit status 2 means the measurement is unavailable
# (not macOS, or no Fiddle).
#
# From Ruby (the tests in spec/spec_ai use this):
#
#   require_relative "../../utils/measure_leak"
#   LeakMeter.bytes_per_call("a.fill(3.5)", setup: "a = ...")
#     # => Float, or nil when unavailable
#
# The child gets this process's $LOAD_PATH, so it loads the same carray.
# A leak shows as a multiple of the buffer that leaks; make that buffer
# large (a wide cell, a long array) so the multiple stands well above the
# few bytes per call that Ruby's own bookkeeping moves.

require "rbconfig"
require "open3"

module LeakMeter

  UNAVAILABLE = 2

  module_function

  def child_script (expr, setup, calls, warmup)
    <<~RUBY
      require "carray"
      $stderr.puts "carray_ext: " + $LOADED_FEATURES.grep(/carray_ext/).first.to_s
      begin
        require "fiddle"
        stats = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      rescue LoadError, Fiddle::DLError
        exit #{UNAVAILABLE}
      end
      in_use = -> {
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        stats.call(nil, buf)
        buf[8, 8].unpack1("Q")          # malloc_statistics_t#size_in_use
      }
      #{setup}
      call = -> { (#{expr}) rescue nil }
      #{warmup}.times { call.() }
      GC.start
      before = in_use.()
      #{calls}.times { call.() }
      GC.start
      puts (in_use.() - before).fdiv(#{calls})
    RUBY
  end

  # Returns [bytes per call or nil, the child's stderr].  Raises when the
  # child fails for any other reason than the measurement being
  # unavailable (a syntax error in +expr+, a raise in +setup+).
  def measure (expr, setup: "", calls: 200, warmup: 50, load_path: $LOAD_PATH)
    return [nil, ""] unless RUBY_PLATFORM =~ /darwin/
    inc = load_path.flat_map { |d| ["-I", d] }
    out, err, status = Open3.capture3(RbConfig.ruby, *inc, "-e",
                                      child_script(expr, setup, calls, warmup))
    return [nil, err] if status.exitstatus == UNAVAILABLE
    raise "measuring process failed:\n#{err}" unless status.success?
    [Float(out), err]
  end

  def bytes_per_call (expr, **opts)
    measure(expr, **opts).first
  end

end

if $0 == __FILE__
  require "optparse"
  opts = {}
  threshold = nil
  parser = OptionParser.new do |o|
    o.banner = "usage: ruby -Iext -Ilib #{File.basename(__FILE__)} [options] EXPR"
    o.on("-s", "--setup CODE", "run once before measuring") { |v| opts[:setup] = v }
    o.on("-n", "--calls N", Integer, "calls measured (default 200)") { |v| opts[:calls] = v }
    o.on("-w", "--warmup N", Integer, "calls before measuring (default 50)") { |v| opts[:warmup] = v }
    o.on("-t", "--threshold BYTES", Float, "exit 1 at or above this") { |v| threshold = v }
  end
  parser.parse!
  abort parser.banner unless ARGV.size == 1
  begin
    bytes, err = LeakMeter.measure(ARGV[0], **opts)
  rescue RuntimeError => e
    abort e.message
  end
  $stderr.print err
  if bytes.nil?
    warn "measurement unavailable (needs macOS and Fiddle)"
    exit LeakMeter::UNAVAILABLE
  end
  puts format("%.1f bytes per call", bytes)
  exit 1 if threshold && bytes >= threshold
end
