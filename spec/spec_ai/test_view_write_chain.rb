require "test/unit"
require "carray"

# Writes through a chain of views reach the root: the cells written and no
# others, whatever the views between them build to carry the write.
class TestViewWriteChain < Test::Unit::TestCase

  def root
    CArray.int32(6, 8).seq!
  end

  def negatives(r)
    r.to_a.flatten.each_with_index.select { |x, _| x < 0 }.map(&:last).sort
  end

  # A reshape over a transpose (or a flip, or a block) is contiguous in its
  # parent's addresses but not in the root's, so its attach builds a buffer.
  # A descriptor view over it must then push that buffer back.
  [
    ["transpose", ->(r) { r.transpose.reshape(6, 8) }],
    ["flip",      ->(r) { r.flip(1).reshape(8, 6) }],
    ["block",     ->(r) { r[1..-1, 1..-1].reshape(7, 5) }],
  ].each do |name, make|
    define_method("test_grid_array_store_through_reshape_over_#{name}") do
      r = root
      v = make.(r)
      expect = v[CA_INT64([2, 0]), CA_INT64([1, 0])].to_a.flatten.sort
      v[CA_INT64([2, 0]), CA_INT64([1, 0])] = CA_INT32([[-1, -2], [-3, -4]])
      assert_equal [-1, -2, -3, -4].sort, r.to_a.flatten.select { |x| x < 0 }.sort
      assert_equal expect.sort, negatives(r).sort
    end

    define_method("test_selection_array_store_through_reshape_over_#{name}") do
      r = root
      v = make.(r)
      b = CArray.boolean(*v.shape); b[] = 0; b[0, 0..2] = 1
      v[b] = CA_INT32([-1, -2, -3])
      assert_equal [-3, -2, -1], r.to_a.flatten.select { |x| x < 0 }.sort
      assert_equal [-1, -2, -3], v[0, 0..2].to_a
    end

    define_method("test_select_axis_array_store_through_reshape_over_#{name}") do
      r = root
      v = make.(r)
      rows = CA_BOOLEAN([1] + [0] * (v.shape[0] - 1))
      v[rows, nil] = CArray.int32(1, v.shape[1]) { -1 }
      assert_equal v.shape[1], r.to_a.flatten.count(-1)
    end
  end

  # A tile repeats its parent's cells.  A write to one copy must not be
  # undone by the copy that was not written.
  def test_region_store_through_reshape_over_tile
    r = CArray.int32(2, 3).seq!
    v = r.tile(1, 2).reshape(6, 2)
    v[nil, -1] = CA_INT32([-1, -2, -3, -4, -5, -6])
    assert_equal [[-2, -1, -3], [-5, -4, -6]], r.to_a
  end

  class Counted < CAObject
    attr_reader :stores, :fetches, :store
    def initialize
      @store   = (0...48).to_a
      @stores  = 0
      @fetches = 0
      super(CA_INT32, [6, 8])
    end
    private
    def fetch_addr(a); @fetches += 1; @store[a]; end
    def store_addr(a, v); @stores += 1; @store[a] = v; end
  end

  # The same write over a root that computes its cells: only the cells
  # written are stored.
  def test_region_store_through_reshape_over_caobject_stores_only_those_cells
    c = Counted.new
    v = c.reshape(8, 6)
    v[nil, -1] = CA_INT32([-1] * 8)
    assert_equal 8, c.stores
    assert_equal 8, c.store.count(-1)
  end

  def test_region_read_through_reshape_over_caobject_fetches_only_those_cells
    c = Counted.new
    assert_equal [5, 11, 17, 23, 29, 35, 41, 47], c.reshape(8, 6)[nil, -1].to_a
    assert_equal 8, c.fetches
  end

  # A byte-swap view held twice by a stack is synced twice; the second sync
  # must not swap the bytes back.
  def test_swap_bytes_twice_in_stack
    a = CArray.int32(3).seq!
    s = a.swap_bytes
    t = CArray.stack([s, s])
    t[] = CA_FLOAT64([[10, 11, 12], [10, 11, 12]])
    assert_equal [10, 11, 12], s.to_a
  end

  def test_swap_bytes_twice_in_meld
    a = CArray.int32(3).seq!
    s = a.swap_bytes
    t = CArray.meld([s, s])
    t[] = CA_FLOAT64([10, 11, 12, 10, 11, 12])
    assert_equal [10, 11, 12], s.to_a
  end

  # A narrower reinterpret with an offset: the mask is read and written at
  # the same cells as the data.
  def test_divided_refer_with_offset_mask_position
    a = CArray.int32(4).seq!
    a[1] = UNDEF
    v = a.refer(:int8, [8], offset: 2)
    assert_equal [false] * 8, v.mask.to_a
    v[0] = UNDEF
    assert_equal [false, true, true, false], a.mask.to_a
  end

  def test_divided_refer_with_offset_reads_parent_mask
    a = CArray.int32(4).seq!
    a[3] = UNDEF
    v = a.refer(:int8, [8], offset: 2)
    assert_equal [false] * 4 + [true] * 4, v.mask.to_a
  end
end
