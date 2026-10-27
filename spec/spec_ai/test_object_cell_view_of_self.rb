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

  # A read through views that only move cells is not recorded, and a cell
  # that holds the view read is still refused, for each such view.
  def test_a_view_held_in_a_cell_of_its_own_array_is_refused_when_read
    views = {
      "grid"   => ->(o) { o[CA_INT64([1, 0, 2])] },
      "select" => ->(o) { o[CA_BOOLEAN([1, 1, 1])] },
      "window" => ->(o) { o.window(0..2) },
      "shift"  => ->(o) { o.shift(1, fill_value: 0) },
      "tile"   => ->(o) { o.tile(2) },
      "roll"   => ->(o) { o.roll(1) },
      "stack"  => ->(o) { CArray.stack([o, o]) },
      "meld"   => ->(o) { CArray.meld(o, o) },
      "remap"  => ->(o) { o.sort },
    }
    views.each do |name, make|
      o = CA_OBJECT([1, 2, 3])
      v = make.(o)
      o[0..0] = [v]
      %i[to_a sum].each do |m|
        e = assert_raise(ArgumentError, "#{name} #{m}") { v.send(m) }
        assert_match(/cyclic/, e.message, "#{name} #{m}")
      end
    end
  end

  # Arrays that share cells but hold no view of themselves compute as usual.
  def test_views_of_the_same_array_as_operands
    o = CA_OBJECT([1, 2, 3, 4]).reshape(2, 2).copy
    assert_equal [[2, 5], [5, 8]], (o + o.transpose).to_a
    assert_equal false, o == o.transpose
    assert_equal [1, 2], o[0, nil].sort.to_a
    assert_equal 10, o.transpose.sum
  end

  # A cell holding a view of other cells of the same array is no cycle:
  # those cells hold numbers.
  def test_a_cell_holding_a_view_of_other_cells
    o = CA_OBJECT([nil, 10, 20, 30]).copy
    o[0..0] = [o[1..2]]
    assert_equal [70, 80], o.sum.to_a
    assert_equal [10, 20], o.abs[0].to_a
  end

  # The same frozen array, shared between Ractors and computed over at the
  # same time, is no re-entry: each computation is the Ractor's own.
  def test_a_shared_frozen_array_computed_from_ractors
    a = Ractor.make_shareable(CA_OBJECT((1..2000).to_a).freeze)
    rs = 8.times.map do
      Ractor.new(a) do |x|
        out = []
        100.times do
          out << begin
                   [x.sum, x.max, x.abs.sum, x[1999], (x == x)]
                 rescue => e
                   e.message
                 end
        end
        out.uniq
      end
    end
    results = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
    assert_equal [[2001000, 2000, 2001000, 2000, true]], results.flatten(1).uniq
  end

  # An element operation called by the computation may compute over the
  # array again.  Running the same computation again from there would never
  # end, and is refused; another computation over the array is not.
  class Element
    attr_reader :v
    def initialize (v) = @v = v
    def + (o)
      $carray_cell_view_probe.call
      Element.new(v + (o.is_a?(Element) ? o.v : o))
    end
    def <=> (o) = v <=> o.v
    def coerce (n) = [Element.new(n), self]
  end

  def test_an_element_operation_computing_over_the_array
    a = CA_OBJECT([Element.new(3), Element.new(1), Element.new(2)])
    $carray_cell_view_probe = -> { a.max }
    assert_equal 6, a.sum.v
    $carray_cell_view_probe = -> { a[0..1].max }
    assert_equal 6, a.sum.v
    $carray_cell_view_probe = -> { a.sum }
    e = assert_raise(ArgumentError) { a.sum }
    assert_match(/cyclic reference is not allowed in CArray/, e.message)
  ensure
    $carray_cell_view_probe = nil
  end

end
