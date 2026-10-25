# spec_ai/test_object_cell_view_of_self_dump.rb
#
# An object array may hold, in a cell, a view of itself.  Marshal.dump of
# such an array would dump the view's cells by a nested dump that does not
# know the outer one, and come back to the same cells without end; it is
# refused as a cyclic reference.  The array itself in a cell (not a view)
# dumps, as Marshal writes one object once.  Each refusal case runs in a
# child process, since the failure being guarded against is the process
# dying.

require "test/unit"
require "carray"
require "rbconfig"
require "open3"

class TestObjectCellViewOfSelfDump < Test::Unit::TestCase
  EXT = File.expand_path("../../ext", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  CELLS = {
    "itself"    => "o",
    "block"     => "o[0, nil]",
    "transpose" => "o.transpose",
    "grid"      => "o[CA_INT64([1, 0]), nil]",
    "remap"     => "o[CA_INT64([[1, 0, 2], [2, 1, 0]])]",
  }


  def run_child (script)
    Open3.capture2e(RbConfig.ruby, "-I", EXT, "-I", LIB, "-rcarray",
                    "-e", script)
  end

  def build (cell)
    "o = CA_OBJECT([1, 2, 3, 4, 5, 6]).reshape(2, 3).copy; " \
    "o[0..1, 0] = [#{cell}, 1]"
  end

  def test_dump_is_refused_and_the_process_goes_on
    bad = []
    (CELLS.keys - ["itself"]).each do |name|
      script = build(CELLS[name]) + "\n" + <<~RUBY
        2.times do
          begin
            Marshal.dump(o)
            puts "dumped"
          rescue ArgumentError => e
            raise e unless e.message =~ /cyclic/
          end
        end
        puts "alive"
      RUBY
      out, status = run_child(script)
      bad << "#{name}: #{status.inspect} #{out.lines.last(2).join.strip}" unless status.success? && out =~ /alive/ && out !~ /dumped/
    end
    assert_equal [], bad
  end

  # The array holding itself (not a view) dumps: Marshal keeps the one
  # object once.  Loading it back gives a cell that is the loaded array.
  def test_the_array_itself_in_a_cell_dumps
    o = CA_OBJECT([1, 2, 3, 4]).reshape(2, 2).copy
    o[0..1, 0] = [o, 1]
    r = Marshal.load(Marshal.dump(o))
    assert_equal [2, 2], r.shape
  end

  # A cell holding a view of a different array dumps and computes.
  def test_a_view_of_another_array_in_a_cell
    other = CA_OBJECT([10, 20, 30])
    o = CA_OBJECT([1, 2, 3]).copy
    o[0] = other[0..1]
    r = Marshal.load(Marshal.dump(o))
    assert_equal [10, 20], r[0].to_a
    assert_equal [11, 21], (o[0] + 1).to_a
  end
end
