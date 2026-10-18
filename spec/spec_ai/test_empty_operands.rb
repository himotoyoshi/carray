# An operation over no cells computes nothing.  An operator whose result
# has an axis of length 0 returns that empty result without touching a
# cell, however its operands reach it: broadcast from a row, through a
# view that is not contiguous, with a mask, or holding objects.
#
# The strided walks inside the operators hand the kernel a first row before
# they look at the outer counts, so the operators return before them; the
# rows here are long so that a row read or written past an empty buffer
# shows.  utils/check_empty_walks.rb asks every such walk to say where an
# empty extent is caught.

require "test/unit"
require "carray"

class TestEmptyOperands < Test::Unit::TestCase

  W = 4096

  def empty   = CArray.int64(0, W)
  def row     = CArray.int64(1, W) { 3 }
  def view    = CArray.int64(W, 0).transpose
  def fempty  = CArray.float64(0, W)
  def frow    = CArray.float64(1, W) { 2.0 }
  def fview   = CArray.float64(W, 0).transpose
  def masked
    a = CArray.int64(W, 0)
    a.mask = 0
    a.transpose
  end

  OPERATIONS = {
    "empty + row"        => ->(t) { t.empty + t.row },
    "row + empty"        => ->(t) { t.row + t.empty },
    "view + empty"       => ->(t) { t.view + t.empty },
    "view + view"        => ->(t) { t.view + t.view },
    "empty / row of 0"   => ->(t) { t.empty / CArray.int64(1, W) },
    "empty % row of 0"   => ->(t) { t.empty % CArray.int64(1, W) },
    "masked + empty"     => ->(t) { t.masked + t.empty },
    "masked row"         => ->(t) { m = t.empty; m.mask = 0; m + t.row },
    "empty < row"        => ->(t) { t.empty < t.row },
    "view.eq(view)"      => ->(t) { t.view.eq(t.view) },
    "-view"              => ->(t) { -t.view },
    "view.sqrt"          => ->(t) { t.fview.sqrt },
    "view.abs"           => ->(t) { t.view.abs },
    "view.is_nan"        => ->(t) { t.fview.is_nan },
    "fma with row"       => ->(t) { t.fempty.fma(t.frow, t.fempty) },
    "object + row"       => ->(t) { CArray.object(0, W) + CArray.object(1, W) { 1 } },
    "then_else with row" => ->(t) { CArray.boolean(0, W).then_else(t.row, t.empty) },
    "lazy fma with row"  => ->(t) { t.fempty.lazy.fma(t.frow, t.fempty).copy },
    "add! a row"         => ->(t) { x = t.empty; x.add!(t.row); x },
  }

  def test_an_operation_over_no_cells_returns_an_empty_result
    OPERATIONS.each do |name, op|
      r = op.(self)
      assert_equal [0, W], r.shape, name
      assert_equal [], r.to_a, name
    end
  end

  # The same lazily, where the walk is the lazy expression's own.
  def test_a_lazy_expression_over_no_cells_is_empty
    r = (empty.lazy + row).copy
    assert_equal [0, W], r.shape
    r = (empty.lazy / CArray.int64(1, W)).copy
    assert_equal [0, W], r.shape
  end

end
