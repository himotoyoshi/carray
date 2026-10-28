# spec_ai/test_object_cell_lazy_of_self.rb
#
# A cell of an object array can hold a lazy expression over the array
# itself (an assignment from a Ruby Array is not checked).  Evaluating the
# expression comes back to the cell, which holds the expression again;
# comparing, computing over or inspecting either the array or the
# expression is refused as cyclic, whatever the shape of the expression,
# rather than overflowing the stack or running without end.  A cell holding
# a comparison over the array, whose cells it does not need again, is no
# cycle.  Each case runs in a child process with a time limit, since the
# failures being guarded against are the process dying and hanging.

require "test/unit"
require "carray"
require "rbconfig"
require "open3"
require "timeout"

class TestObjectCellLazyOfSelf < Test::Unit::TestCase

  EXT = File.expand_path("../../ext", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  CYCLIC = {
    "unary"      => "-o.lazy",
    "unary pair" => "(-o.lazy).abs",
    "binop"      => "o.lazy + 1",
    "both sides" => "o.lazy + o.lazy",
    "triop"      => "o.lazy.fma(o.lazy, o.lazy)",
  }

  OPS = ["x == x", "o == o.copy", "x.copy", "x.inspect", "o.inspect"]

  def run_child (script)
    out = +""
    status = nil
    Open3.popen2e(RbConfig.ruby, "-I", EXT, "-I", LIB, "-rcarray",
                  "-e", script) do |_in, io, th|
      begin
        Timeout.timeout(30) { out = io.read; status = th.value }
      rescue Timeout::Error
        Process.kill(:KILL, th.pid)
        out = "timed out"
      end
    end
    [out, status]
  end

  def script (cell)
    <<~RUBY
      #{OPS.inspect}.each do |op|
        o = CA_OBJECT([1, 2, 3]); x = #{cell}; o[0..0] = [x]
        begin
          eval(op)
          puts "passed \#{op}"
        rescue ArgumentError => e
          raise "\#{op}: \#{e.message}" unless e.message =~ /cyclic/
        end
      end
      puts "alive"
    RUBY
  end

  def test_an_expression_over_the_array_in_its_cell_is_refused
    bad = []
    CYCLIC.each do |name, cell|
      out, status = run_child(script(cell))
      unless status&.success? && out =~ /alive/ && out !~ /passed/
        bad << "#{name}: #{status.inspect} #{out.lines.last(2).join.strip}"
      end
    end
    assert_equal [], bad
  end

  # x == 1 for a cell holding x does not evaluate x.
  def test_a_comparison_over_the_array_in_its_cell_is_no_cycle
    o = CA_OBJECT([1, 2, 3])
    x = o.lazy.eq(1)
    o[0..0] = [x]
    assert_equal true, o == o.copy
    assert_equal [false, false, false], x.to_a
    assert_match(/CAMonCmp|CArray/, o.inspect)
  end

  # A cell holding a view of other cells is shown, not refused.
  def test_inspect_shows_a_cell_holding_a_view_of_other_cells
    o = CA_OBJECT([nil, 10, 20])
    o[0..0] = [o[1..2]]
    assert_match(/10, 20/, o.inspect)
    assert_match(/10, 20/, o.inspect_full)
  end
end
