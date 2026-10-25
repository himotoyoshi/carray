# spec_ai/test_object_cell_view_of_self.rb
#
# An object array may hold, in a cell, a view of itself: the array, a block
# of it, or a view that reorders its cells (transpose, an index array, a
# remap).  Writing such a cell is allowed; computing over the array would
# come back into the same cells without end, and is refused as a cyclic
# reference -- whichever kind of view the cell holds.  The refusal leaves
# the process able to go on.  Each case runs in a child process, since the
# failure being guarded against is the process dying.

require "test/unit"
require "carray"
require "rbconfig"
require "open3"

class TestObjectCellViewOfSelf < Test::Unit::TestCase

  EXT = File.expand_path("../../ext", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  CELLS = {
    "itself"    => "o",
    "block"     => "o[0, nil]",
    "transpose" => "o.transpose",
    "grid"      => "o[CA_INT64([1, 0]), nil]",
    "remap"     => "o[CA_INT64([[1, 0, 2], [2, 1, 0]])]",
  }

  OPS = %w[sum sort abs max lt(0) sum(axis:\ 0) median]

  def run_child (script)
    Open3.capture2e(RbConfig.ruby, "-I", EXT, "-I", LIB, "-rcarray",
                    "-e", script)
  end

  def build (cell)
    "o = CA_OBJECT([1, 2, 3, 4, 5, 6]).reshape(2, 3).copy; " \
    "o[0..1, 0] = [#{cell}, 1]"
  end

  def test_computing_over_the_array_is_refused_and_the_process_goes_on
    bad = []
    CELLS.each do |name, cell|
      script = build(cell) + "\n" + <<~RUBY
        #{OPS.inspect}.each do |op|
          2.times do
            begin
              o.instance_eval(op)
              puts "passed \#{op}"
            rescue ArgumentError => e
              raise "\#{op}: \#{e.message}" unless e.message =~ /cyclic/
            end
          end
        end
        puts "alive"
      RUBY
      out, status = run_child(script)
      bad << "#{name}: #{status.inspect} #{out.lines.last(2).join.strip}" unless status.success? && out =~ /alive/ && out !~ /passed/
    end
    assert_equal [], bad
  end

  # Arrays that share cells but hold no view of themselves compute as usual.
  def test_views_of_the_same_array_as_operands
    o = CA_OBJECT([1, 2, 3, 4]).reshape(2, 2).copy
    assert_equal [[2, 5], [5, 8]], (o + o.transpose).to_a
    assert_equal false, o == o.transpose
    assert_equal [1, 2], o[0, nil].sort.to_a
    assert_equal 10, o.transpose.sum
  end

end
