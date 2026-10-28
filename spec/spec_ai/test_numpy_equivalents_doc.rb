# spec_ai/test_numpy_equivalents_doc.rb
#
# docs/topics/NumPyEquivalents.md names CArray methods in the CArray and
# Also columns of every table.  Each name must exist, so that a rename in
# the library cannot leave the table pointing at a method that is gone.

require "test/unit"
require "carray"

class TestNumPyEquivalentsDoc < Test::Unit::TestCase

  DOC = File.expand_path("../../docs/topics/NumPyEquivalents.md", __dir__)

  # Receivers the table uses for an instance of CArray.
  RECEIVERS = %w[a b c m t x y z q u v k fp xp temp]

  # Methods the table calls on something other than a CArray: the step of
  # a Range, and the methods of the iterator that `windows` returns.
  OTHER_OWNERS = {
    "step"      => Range,
    "correlate" => CAWindowIterator,
    "convolve"  => CAWindowIterator,
  }

  def carray_cells
    File.readlines(DOC, encoding: "UTF-8").filter_map { |line|
      next unless line.start_with?("|")
      cells = line.split("|").map(&:strip)
      next if cells[1] == "NumPy" || cells[1].start_with?("---") ||
              cells[1].start_with?("NumPy (")
      cells[2] + " " + cells[3].to_s
    }
  end

  def names_in (cell)
    instance = []
    klass = []
    frame = []
    frame_class = []
    cell.scan(/`([^`]+)`/).flatten.each do |code|
      code.scan(/(?<![\w.])(?:#{RECEIVERS.join("|")})\.([a-z_]\w*[!?]?)/) { instance << $1 }
      code.scan(/\)\.([a-z_]\w*[!?]?)/) { instance << $1 }
      code.scan(/\bCArray\.([a-z_]\w*[!?]?)/) { klass << $1 }
      code.scan(/(?<![\w.])df\.([a-z_]\w*[!?]?)/) { frame << $1 }
      code.scan(/\bCAFrame\.([a-z_]\w*[!?]?)/) { frame_class << $1 }
    end
    [instance, klass, frame, frame_class]
  end

  def test_every_named_method_exists
    missing = []
    seen = 0
    carray_cells.each do |cell|
      instance, klass, frame, frame_class = names_in(cell)
      instance.each do |name|
        seen += 1
        owner = OTHER_OWNERS.fetch(name, CArray)
        missing << "#{owner}##{name}" unless owner.method_defined?(name)
      end
      klass.each do |name|
        seen += 1
        missing << "CArray.#{name}" unless CArray.respond_to?(name)
      end
      frame.each do |name|
        seen += 1
        missing << "CAFrame##{name}" unless CAFrame.method_defined?(name)
      end
      frame_class.each do |name|
        seen += 1
        missing << "CAFrame.#{name}" unless CAFrame.respond_to?(name)
      end
    end
    assert_operator seen, :>, 100, "the table parser found too few names"
    assert_empty missing, "names in NumPyEquivalents.md that CArray lacks"
  end

end
