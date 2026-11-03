$:.unshift File.expand_path("../../ext", __dir__)
$:.unshift File.expand_path("../../lib", __dir__)
require "test/unit"
require "carray"
require "open3"
require "rbconfig"

# A cell can hold a lazy expression over an array that holds the first one.
# Opening such a cell gives a new array each time, so the walks into cells
# never come back to an array they have seen; they stop at a limit on the
# depth instead.  The walks that did not stop would hang a test run, so each
# case runs in a process of its own.
class TestCellNestingLimit < Test::Unit::TestCase

  LIBS = %w[ext lib].map { |d| File.expand_path("../../#{d}", __dir__) }

  PRELUDE = <<~'RUBY'
    require "carray"
    def endless (make)
      o = CA_OBJECT([1, 2])
      q = CA_OBJECT([1, 2])
      o[0] = make.call(q)
      q[0] = o
      o
    end
    BINOP = ->(q) { q.lazy + 1 }
    def nested (n)
      a = CA_OBJECT([1])
      n.times { b = CA_OBJECT([1]); b[0] = a; a = b }
      a
    end
    def report
      value = yield
      puts "ok #{value.inspect[0, 60]}"
    rescue ArgumentError => e
      puts "refused #{e.message}"
    end
  RUBY

  def run_case (body, limit: 30)
    cmd = [RbConfig.ruby, *LIBS.flat_map { |d| ["-I", d] }, "-e", PRELUDE + body]
    Open3.popen2e(*cmd) do |stdin, out, waiter|
      stdin.close
      reader = Thread.new { out.read }
      reader.report_on_exception = false
      unless waiter.join(limit)
        Process.kill("KILL", waiter.pid)
        reader.join
        flunk "did not end in #{limit} seconds: #{body}"
      end
      return reader.value
    end
  end

  def assert_refused (body)
    assert_match(/\Arefused .*nested too deep: more than 256 levels/, run_case(body))
  end

  def test_hash_is_refused
    assert_refused "report { endless(BINOP).hash }"
  end

  def test_the_value_hash_family_is_refused
    assert_refused "report { endless(BINOP).unique }"
    assert_refused "report { endless(BINOP).value_counts }"
    assert_refused "report { endless(BINOP).is_in([1]) }"
  end

  def test_comparison_is_refused
    assert_refused "report { a = endless(BINOP); a == a.copy }"
    assert_refused "report { a = endless(BINOP); a.eql?(a.copy) }"
  end

  def test_marshal_is_refused
    assert_refused "report { Marshal.dump(endless(BINOP)) }"
  end

  def test_a_computation_calling_the_cells_is_refused
    assert_refused "report { endless(BINOP).round(1) }"
    assert_refused "report { endless(BINOP).match(1) }"
  end

  def test_a_refused_walk_leaves_nothing_behind
    out = run_case(<<~'RUBY')
      begin
        endless(BINOP).hash
      rescue ArgumentError
      end
      p Thread.current.keys
      p nested(200).hash.is_a?(Integer)
    RUBY
    assert_equal "[]\ntrue\n", out
  end

  def test_nesting_within_the_limit_is_walked
    assert_match(/\Aok /, run_case("report { nested(255).hash }"))
    assert_match(/\Aok /, run_case("report { nested(255) == nested(255) }"))
    assert_match(/\Aok /, run_case("report { Marshal.load(Marshal.dump(nested(255)[0..0])).class }"))
  end

  def test_nesting_past_the_limit_is_refused
    assert_refused "report { nested(300).hash }"
    assert_refused "report { nested(300) == nested(300) }"
    assert_refused "report { nested(300).unique }"
  end

  def test_each_fiber_counts_for_itself
    out = run_case(<<~'RUBY')
      def down (a, n)
        return Fiber.new { a.hash.class }.resume if n == 0
        CA_OBJECT([Class.new { define_method(:hash) { down(a, n - 1) ; 1 } }.new]).hash
      end
      report { down(nested(200), 100) }
    RUBY
    assert_match(/\Aok /, out)
  end

  def test_a_frozen_thread_still_hashes
    out = run_case(<<~'RUBY')
      Thread.new {
        Thread.current.freeze
        report { nested(3).hash }
      }.join
    RUBY
    assert_match(/\Aok /, out)
  end

  def test_other_data_types_are_not_counted
    a = CA_INT32([1, 2, 3])
    assert_equal a.hash, a.copy.hash
    assert_equal true, a == a.copy
  end

end
