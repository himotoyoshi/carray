# spec_ai/test_stride_compose_shared_axis.rb
#
# A view on top of a reshape can have two of its axes advance the same axis
# of a strided parent: a block of `a.flip(1).reshape(6, 4)` moves 4 cells
# per row and 1 cell per column, and both are steps along the parent's
# columns.  The view folds onto the parent only while the two steps together
# stay inside that axis; a block that crosses into the next parent row has
# no single stride per axis and is read and written cell by cell.  Every
# case here compares with the same view built over a materialised copy of
# the middle layer.

require "test/unit"
require "carray"

class TestStrideComposeSharedAxis < Test::Unit::TestCase

  # Views whose block crosses a parent row, with the reference that reads
  # the same cells after the middle layer is copied.
  CASES = {
    "flip(1).reshape(6,4)[0..1,nil]" => [
      ->(a) { a.flip(1).reshape(6, 4)[0..1, nil] },
      ->(a) { a.flip(1).copy.reshape(6, 4)[0..1, nil] } ],
    "[1..2,1..3].reshape(3,2)[0..1,nil]" => [
      ->(a) { a[1..2, 1..3].reshape(3, 2)[0..1, nil] },
      ->(a) { a[1..2, 1..3].copy.reshape(3, 2)[0..1, nil] } ],
    "[[nil,2],[nil,2]].reshape(3,2)[0..1,0..1]" => [
      ->(a) { a[[nil, 2], [nil, 2]].reshape(3, 2)[0..1, 0..1] },
      ->(a) { a[[nil, 2], [nil, 2]].copy.reshape(3, 2)[0..1, 0..1] } ],
    "transpose.reshape(6,4)[0..1,nil]" => [
      ->(a) { a.transpose.reshape(6, 4)[0..1, nil] },
      ->(a) { a.transpose.copy.reshape(6, 4)[0..1, nil] } ],
  }

  def root (type = CA_INT32)
    CArray.new(type, [4, 6]).seq!
  end

  def test_read_matches_the_copied_middle
    [CA_INT32, CA_FLOAT64].each do |t|
      CASES.each do |name, (view, ref)|
        a = root(t)
        assert_equal ref.(a).to_a, view.(a).to_a, "#{name} #{t}"
        assert_equal ref.(a).to_a, view.(a).copy.to_a, "#{name} #{t} copy"
        assert_equal ref.(a).sum, view.(a).sum, "#{name} #{t} sum"
        assert_equal ref.(a).sort.to_a, view.(a).sort.to_a, "#{name} #{t} sort"
      end
    end
  end

  def test_the_three_by_two_transpose
    b = CArray.int32(3, 2).seq!
    assert_equal [[0, 2], [4, 1]], b.transpose.reshape(3, 2)[0..1, 0..1].to_a
  end

  # The write lands on the cells the view reads and nowhere else.
  def test_write_reaches_the_cells_it_names
    CASES.each do |name, (view, ref)|
      a = root(CA_FLOAT64)
      marks = ref.(a).to_a.flatten
      view.(a)[] = -1.0
      expected = root(CA_FLOAT64).to_a.flatten.map { |x| marks.include?(x) ? -1.0 : x }
      assert_equal expected, a.to_a.flatten, name
    end
  end

  def test_object_cells_under_gc
    20.times do
      b = CArray.object(3, 2).seq!
      assert_equal [[0, 2], [4, 1]], b.transpose.reshape(3, 2)[0..1, 0..1].to_a
      GC.start
    end
  end

  # A view that is exported through MemoryView carries strides that reach
  # the same cells.
  def test_memory_view_export
    CASES.each do |name, (view, ref)|
      a = root(CA_FLOAT64)
      v = view.(a)
      next unless CArray.memory_view_available?(v)
      assert_equal ref.(a).to_a, CArray.from_memory_view(v).to_a, name
    end
  end

  # The steps that stay inside the shared axis still fold: a block of
  # rows 0..0 of the reshape over the flip is one parent row.
  def test_a_block_inside_one_parent_row
    a = root
    v = a.flip(1).reshape(6, 4)[0..0, nil]
    assert_equal a.flip(1).copy.reshape(6, 4)[0..0, nil].to_a, v.to_a
    v[] = -1
    assert_equal [-1, -1, -1, -1], a.flip(1)[0, 0..3].to_a
  end
end
