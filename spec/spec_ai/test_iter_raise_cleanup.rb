# spec_ai/test_iter_raise_cleanup.rb
#
# The kernel iterator gathers a slab at a time into scratch of its own.
# When a gather raises (a float64 view over an object array with a cell
# that is not a number), the walk frees that scratch and detaches what it
# attached, rather than leaving them behind -- the caller's loop never
# reaches `ca_iter_state_finish`, since the block macros put it in a `for`
# increment that the raise jumps over, so the walk has to finish itself.
#
# The scratch is plain malloc, invisible from Ruby.  Two ways to see it:
# the malloc zone's bytes-in-use, which is exact but macOS only, and the
# resident size, which is portable but only reads as a leak once the heap
# has stopped growing on its own (a few thousand calls here).

require "test/unit"
require "carray"

class TestIterRaiseCleanup < Test::Unit::TestCase

  N = 1 << 14      # scratch is 128 KB at float64, far above the noise

  def failing_input (n = 8)
    o = CArray.object(n) { 1.0 }
    o[5] = Object.new
    CArray.wrap_readonly(o, CA_FLOAT64)
  end

  # Runs `script` in a fresh process (what earlier tests left in this
  # one's heap moves both measurements) and returns its number.
  def measure (setup, script, n = N)
    prelude = <<~RUBY
      require "carray"
      o = CArray.object(#{n}) { 1.0 }
      o[5] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64)
      #{setup}
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", prelude + script], &:read)
    omit "measurement unavailable" if $?.exitstatus == 2
    assert $?.success?, "measuring process failed"
    Float(out)
  end

  # Bytes added to the malloc zone per call, read through Fiddle.
  def bytes_per_call (expr, setup = "")
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    measure(setup, <<~RUBY)
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
      call = -> { (#{expr}) rescue nil }
      50.times { call.() }
      GC.start
      before = in_use.()
      200.times { call.() }
      GC.start
      puts (in_use.() - before).fdiv(200)
    RUBY
  end

  def assert_frees_scratch (expr, setup = "")
    grown = bytes_per_call(expr, setup)
    assert_operator grown, :<, 4096,
                    "#{expr}: the malloc zone grew #{grown.round} bytes per call"
  end

  def test_raises
    assert_raise(TypeError) { failing_input.cumsum }
    assert_raise(TypeError) { failing_input.sum }
  end

  # A scan walks fibers; the whole view is one fiber here.
  def test_scan_frees_scratch
    assert_frees_scratch("input.cumsum")
  end

  def test_reduction_frees_scratch
    assert_frees_scratch("input.sum")
  end

  # Per-axis: one gather per fiber, and the raise lands in the first.
  def test_per_axis_reduction_frees_scratch
    assert_frees_scratch("input.sum(axis: 1)", "input = input.reshape(64, 256)")
  end

  def test_per_axis_scan_frees_scratch
    assert_frees_scratch("input.cumsum(axis: 1)", "input = input.reshape(64, 256)")
  end

  # An order statistic sorts a copy of each fiber.
  # ---- axis_group ---------------------------------------------------------
  #
  # The group walks hold more than the iterator's own scratch: a plan sized to
  # the slab, per-group accumulators, and a code table read on every cell. The
  # object lane calls back into Ruby for each cell, so a raise part-way through
  # is ordinary there -- an operand that will not coerce, a `<=>` that answers
  # nil -- and it reaches the caller from a plain public call, no `send`.

  def group_setup (n)
    <<~RUBY
      n = #{n}
      cat = CACategorical.from_codes(CArray.uint8(n) { |i| i % 2 }, ["a", "b"])
    RUBY
  end

  def test_object_group_scan_frees_its_plan_when_a_cell_will_not_coerce
    setup = group_setup(4096) + <<~RUBY
      input = CArray.object(n) { |i| i < n - 1 ? 1 : Object.new }
    RUBY
    assert_frees_scratch("input.group_by_category(cat).cumsum", setup)
  end

  def test_object_group_scan_frees_its_plan_when_a_comparison_answers_nil
    # NUM2INT on the nil that `1 <=> "s"` returns -- the likeliest way to get
    # here by accident with an object array
    setup = group_setup(4096) + <<~RUBY
      input = CArray.object(n) { |i| i < n - 1 ? 1 : "s" }
    RUBY
    assert_frees_scratch("input.group_by_category(cat).cummax", setup)
  end

  def test_group_reduce_frees_what_it_holds_when_the_gather_raises
    setup = group_setup(2048) + <<~RUBY
      o = CArray.object(n, 2) { 1.0 }
      o[n - 1, 1] = Object.new
      input = CArray.wrap_readonly(o, CA_FLOAT64)
    RUBY
    assert_frees_scratch("input[cat, nil].sum(axis: :group)", setup)
  end

  def test_the_group_raises_are_reachable_without_send
    n = 64
    cat = CACategorical.from_codes(CArray.uint8(n) { |i| i % 2 }, ["a", "b"])
    assert_raise(TypeError) {
      CArray.object(n) { |i| i < n - 1 ? 1 : Object.new }.group_by_category(cat).cumsum
    }
    assert_raise(TypeError) {
      CArray.object(n) { |i| i < n - 1 ? 1 : "s" }.group_by_category(cat).cummax
    }
  end

  def test_median_frees_scratch
    assert_frees_scratch("input.median")
  end

  # The same thing seen portably: the resident size stops growing.  It
  # takes several thousand calls to settle whether or not anything leaks
  # (and it settles into a wobble of a few MB), so those are not
  # measured, and the array is small enough that the settling is quick
  # while a leak would still show: 32 KB a call is 320 MB over the
  # measured window.
  def test_resident_size_levels_off
    grown = measure("", <<~RUBY, 4096)
      rss = -> { Integer(`ps -o rss= -p \#{Process.pid}`.strip, exception: false) }
      exit 2 unless rss.()
      call = -> { input.cumsum rescue nil }
      10_000.times { call.() }
      GC.start
      r0 = rss.()
      10_000.times { call.() }
      GC.start
      puts (rss.() - r0) / 1024.0
    RUBY
    assert_operator grown, :<, 40,
                    "resident size grew #{grown.round} MB over 10000 calls"
  end
end
