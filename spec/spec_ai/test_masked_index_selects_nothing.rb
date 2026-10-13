# A masked cell of an index CArray selects nothing.  On read the position
# stays and reads as masked; on write the position takes nothing.  Every
# door that takes integer positions answers the same way.
#
# The table below walks the doors against index arrays of every integer
# type, with the masked cells in different places, over parents of
# different kinds.  The expected answer is worked out from plain Ruby
# arrays, not from another CArray path.

require "carray"
require "test/unit"

class TestMaskedIndexSelectsNothing < Test::Unit::TestCase

  INDEX_TYPES = [CA_INT8, CA_INT16, CA_INT32, CA_INT64,
                 CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64]

  # positions of [2, 0, 1, 2] that are masked
  MASKS = { "none" => [], "first" => [0], "middle" => [1, 2],
            "last" => [3], "all" => [0, 1, 2, 3] }

  INDEX_VALUES = [2, 0, 1, 2]

  def index_array (type, masked)
    i = CArray.new(type, [4]); i[] = INDEX_VALUES
    masked.each { |k| i[k] = UNDEF }
    i
  end

  # parents of 3 cells: [10, 20, 30] in different kinds
  PARENTS = {
    "entity"  => -> { CA_INT32([10, 20, 30]) },
    "view"    => -> { CA_INT32([0, 10, 20, 30])[1..3] },
    "masked"  => -> { a = CA_INT32([10, 20, 30, 0]); a[3] = UNDEF; a[0..2] },
    "object"  => -> { CA_OBJECT([10, 20, 30]) },
    "lazy"    => -> { CA_INT32([10, 20, 30]).lazy },
  }

  def expected_read (src, idx, masked)
    idx.each_with_index.map { |v, k| masked.include?(k) ? UNDEF : src[v] }
  end

  READ_DOORS = {
    "x[i]"            => ->(x, i) { x[i] },
    "x[i].copy"       => ->(x, i) { x[i].copy },
    "x.project(i)"    => ->(x, i) { x.project(i) },
    "take_along_axis" => ->(x, i) { x.take_along_axis(i, axis: 0) },
    "gather_nd"       => ->(x, i) { x.gather_nd(i.reshape(4, 1)) },
    "x.grid(i)"       => ->(x, i) { x.grid(i) },
  }

  READ_DOORS.each do |door, fn|
    PARENTS.each do |pname, mk|
      define_method("test_read #{door} over #{pname}") do
        INDEX_TYPES.each do |type|
          MASKS.each do |mname, masked|
            i   = index_array(type, masked)
            got = fn.call(mk.call, i)
            assert_equal expected_read([10, 20, 30], INDEX_VALUES, masked),
                         got.to_a, "#{door} #{pname} #{type} mask=#{mname}"
            assert_equal [4], got.shape
          end
        end
      end
    end
  end

  # Writes: positions whose index cell is masked take nothing.
  def expected_write (idx, masked, vals)
    dst = [10, 20, 30]
    idx.each_with_index { |v, k| dst[v] = vals[k] unless masked.include?(k) }
    dst
  end

  WRITE_DOORS = {
    "y[i] = a"           => ->(y, i, v) { y[i] = v },
    "put_along_axis"     => ->(y, i, v) { y.put_along_axis(i, v, axis: 0) },
    "put_nd"             => ->(y, i, v) { y.put_nd(i.reshape(4, 1), v) },
    "scatter_replace!"   => ->(y, i, v) { y.scatter_replace!(i, v) },
    "y.grid(i)[] = a"    => ->(y, i, v) { y.grid(i)[] = v },
    "y[i].copy-free set" => ->(y, i, v) { w = y[i]; 4.times { |k| w[k] = v[k] } },
  }

  WRITE_PARENTS = {
    "entity" => -> { CA_INT32([10, 20, 30]) },
    "view"   => -> { CA_INT32([0, 10, 20, 30]) },   # written through [1..3]
    "object" => -> { CA_OBJECT([10, 20, 30]) },
  }

  # The scatter family takes numeric and boolean arrays only.
  SCATTER_DOORS = ["put_along_axis", "put_nd", "scatter_replace!"]

  WRITE_DOORS.each do |door, fn|
    WRITE_PARENTS.each do |pname, mk|
      if pname == "object" && SCATTER_DOORS.include?(door)
        define_method("test_write #{door} into object is refused") do
          i = index_array(CA_INT64, [1])
          assert_raise(CArray::DataTypeError) {
            fn.call(mk.call, i, CA_OBJECT([1, 2, 3, 4]))
          }
        end
        next
      end
      define_method("test_write #{door} into #{pname}") do
        INDEX_TYPES.each do |type|
          MASKS.each do |mname, masked|
            root = mk.call
            y    = pname == "view" ? root[1..3] : root
            i    = index_array(type, masked)
            vals = [1, 2, 3, 4]
            fn.call(y, i, CArray.new(y.data_type, [4]).tap { |a| a[] = vals })
            got = pname == "view" ? root[1..3].to_a : root.to_a
            # the last write to a duplicated position wins
            assert_equal expected_write(INDEX_VALUES, masked, vals), got,
                         "#{door} #{pname} #{type} mask=#{mname}"
          end
        end
      end
    end
  end

  # A scalar write through the view leaves the holes' parents alone.
  def test_fill_through_a_view_skips_the_holes
    y = CA_INT32([10, 20, 30])
    i = CA_INT64([2, 0]); i[1] = UNDEF
    y[i] = 5
    assert_equal [10, 20, 5], y.to_a
  end

  # Writing UNDEF through the view masks only the selected cells.
  def test_masking_through_a_view_skips_the_holes
    y = CA_INT32([10, 20, 30])
    i = CA_INT64([2, 0]); i[1] = UNDEF
    y[i] = UNDEF
    assert_equal [10, 20, UNDEF], y.to_a
  end

  # The mask of the view reads true at a hole, and unmasking it leaves the
  # hole masked and the parent alone.
  def test_the_mask_of_a_hole
    y = CA_INT32([10, 20, 30]); y[1] = UNDEF
    i = CA_INT64([1, 0, 2]); i[2] = UNDEF
    v = y[i]
    assert_equal [true, false, true], v.mask.to_a
    v.mask = 0
    assert_equal [20, 10, UNDEF], v.to_a
    assert_equal [10, 20, 30], y.to_a
  end

  # Showing the holes gives a parent that has no mask none: reading, and
  # writing values or false into the mask, leave it without one.
  NO_MASK_OPS = {
    "to_a"      => ->(v) { v.to_a },
    "copy"      => ->(v) { v.copy },
    "sum"       => ->(v) { v.sum },
    "sort"      => ->(v) { v.sort.to_a },
    "mask"      => ->(v) { v.mask.to_a },
    "is_masked" => ->(v) { v.is_masked.to_a },
    "lazy"      => ->(v) { (v.lazy + 1).copy },
    "add!"      => ->(v) { v.add!(1) },
    "mask.dup"  => ->(v) { v.mask.dup.to_a },
    "unmask"    => ->(v) { v.unmask(0) },
    "mask = 0"  => ->(v) { v.mask = 0 },
    "fill"      => ->(v) { v[] = 5 },
    "inspect"   => ->(v) { v.inspect },
  }

  def test_no_mask_is_made_on_the_parent
    NO_MASK_OPS.each do |name, op|
      i = CA_INT64([2, 0, 1]); i[1] = UNDEF
      x = CA_INT32([10, 20, 30])
      op.call(x[i])
      assert_equal false, x.has_mask?, name
      t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"])
      op.call(t[i]) rescue nil
      assert_equal false, t.has_mask?, "#{name} (CATime)"
    end
  end

  # A mask the parent gains later is read through the view, and a true
  # written into the view's mask reaches the parent.
  def test_the_parent_mask_comes_and_goes_through_the_view
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    x = CA_INT32([10, 20, 30])
    v = x[i]
    m = v.mask
    assert_equal [false, true, false], m.to_a
    x[2] = UNDEF
    assert_equal [true, true, false], m.to_a
    assert_equal [UNDEF, UNDEF, 20], v.to_a
    y = CA_INT32([10, 20, 30])
    w = y[i].mask.dup
    GC.start
    w[2] = true
    assert_equal [10, UNDEF, 30], y.to_a
  end

  # Both axes of a grid, and the axes of a mapping.
  def test_grid_holes_on_two_axes
    x = CA_INT32([[10, 20, 30], [40, 50, 60], [70, 80, 90]])
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    j = CA_INT64([0, 2]);    j[0] = UNDEF
    assert_equal [[UNDEF, 90], [UNDEF, UNDEF], [UNDEF, 60]], x[i, j].to_a
    assert_equal [[70, 80, 90], [UNDEF, UNDEF, UNDEF], [40, 50, 60]], x[i, nil].to_a
    assert_equal [[30, UNDEF, 20], [60, UNDEF, 50], [90, UNDEF, 80]], x[nil, i].to_a
  end

  def test_mapping_hole
    x = CA_INT32([[10, 20, 30], [40, 50, 60], [70, 80, 90]])
    a = CA_INT64([[0, 4], [8, 1]]); a[0, 1] = UNDEF
    assert_equal [[10, UNDEF], [90, 20]], x[a].to_a
    assert_equal [[10, UNDEF], [90, 20]], x.project(a).to_a
    y = x.copy
    y[a] = 0
    assert_equal [[0, 0, 30], [40, 50, 60], [70, 80, 0]], y.to_a
  end

  # A reduction along the view counts the holes as masked cells.
  def test_reductions_see_holes_as_masked
    x = CA_INT32([[1, 2], [3, 4], [5, 6]])
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    v = x[i, nil]
    assert_equal [11.0, 0.0, 7.0], v.sum(axis: 1).to_a
    assert_equal [5.5, UNDEF, 3.5], v.mean(axis: 1).to_a
    assert_equal 2, v.count_masked
  end

  # Lazy views and the kernel walk see the same holes.
  def test_lazy_and_in_place
    x = CA_INT32([10, 20, 30])
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    assert_equal [31, UNDEF, 21], (x[i].lazy + 1).copy.to_a
    y = x.copy
    y[i].add!(1)
    assert_equal [10, 21, 31], y.to_a
  end

  # A Face keeps its type, and its holes read as masked.
  def test_face_holes
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"])
    i = CA_INT64([2, 0]); i[1] = UNDEF
    v = t[i]
    assert_kind_of CATime, v
    assert_equal [false, true], v.is_masked.to_a
    s = CArray.const_string(["a", "bb", "c"])
    assert_equal ["c", UNDEF], s[i].to_a
  end

  # An empty parent: every selected position is a hole.
  def test_holes_over_an_empty_parent
    i = CA_INT64([0, 0]); i[] = UNDEF
    assert_equal [UNDEF, UNDEF], CA_INT32([])[i].to_a
    y = CA_INT32([])
    y[i] = 5
    assert_equal [], y.to_a
  end

  # CA_OBJECT cells gathered through holes stay alive under GC.
  def test_object_holes_under_gc_stress
    o = CA_OBJECT(["a", "b", "c"])
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    GC.stress = true
    got = o[i].copy.to_a
    GC.stress = false
    assert_equal ["c", UNDEF, "b"], got
  ensure
    GC.stress = false
  end

  # A row selector with a masked cell gives a row of masked cells.
  def test_frame_rows
    df = CAFrame.new({ "a" => CA_INT32([1, 2, 3]) },
                     index: CA_INT32([100, 200, 300]), axis_name: "id")
    i = CA_INT64([2, 0, 1]); i[1] = UNDEF
    sub = df[i]
    assert_equal 3, sub.nrow
    assert_equal [3, UNDEF, 2], sub["a"].to_a
    assert_equal [300, UNDEF, 200], sub.index.to_a
  end

  # A view of a value array can never carry a mask, so it can not show a
  # hole.
  def test_value_array_refuses_holes
    x = CA_INT32([10, 20, 30])
    i = CA_INT64([2, 0]); i[1] = UNDEF
    assert_raise(ArgumentError) { x.value[i] }
  end
end
