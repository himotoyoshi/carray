require "test/unit"
require "carray"

# Regression: a view over a CAObject (or any other non-entity boundary root)
# must reach a kernel through the region protocol, asking the root only for
# the cells the view covers.
#
# The xfer path already did this -- `roi.copy` on a CAObject slice arrives as
# one copy_block for exactly that block.  The kernel iterator did not: its L2
# CAStride branch composed the leaf strides down to the root and called
# ca_attach(root), which for a non-entity root means one whole-root
# materialise no matter how few cells the view touches.  So `roi.copy` and
# `roi.sum` on the same view disagreed about how much data they pulled.
#
# The claim in docs/topics/CAObject.md that partial requests never escalate to
# a whole-view materialise is what makes this a correctness-shaped bug rather
# than a slow path: the backing CAObject is typically lazy (a file, a DB, a
# paginated fetch), where "read all of it" is not slow but fatal.
class TestCAObjectViewRegion < Test::Unit::TestCase

  SHAPE = [64, 96]

  # Records every bulk request the engine makes, and serves them from a plain
  # CArray so values can be checked against it directly.
  class Recorder < CAObject
    attr_reader :log, :back

    def initialize(back)
      @back = back
      @log  = []
      super(CA_INT32, back.shape, read_only: true)
    end

    def cells_requested
      @log.sum { |kind, n| n }
    end

    private

    def fetch_addr(addr)
      @log << [:cell, 1]
      @back[addr]
    end

    def copy_data(data)
      @log << [:copy_data, @back.elements]
      data[] = @back
    end

    def copy_block(starts, counts, steps, data)
      @log << [:copy_block, counts.to_a.inject(:*)]
      data[] = @back[*starts.each_index.map { |k| [starts[k], counts[k], steps[k]] }]
    end

    def copy_addrs(addrs, data)
      @log << [:copy_addrs, addrs.elements]
      data[] = @back[addrs]
    end
  end

  def setup
    @back = CArray.int32(*SHAPE) { |i| i * 7 % 1013 }
    @src  = Recorder.new(@back)
  end

  # --- the escalation itself -------------------------------------------

  # A kernel over a slice must not pull more cells than the slice holds.
  # Before the fix each of these logged copy_data for all 6144 cells.
  def test_reduction_over_a_slice_asks_only_for_the_slice
    view = @src[8...24, 16...48]
    assert_equal @back[8...24, 16...48].sum, view.sum
    assert_equal 16 * 32, @src.cells_requested
  end

  def test_reduction_over_a_single_column_asks_only_for_the_column
    view = @src[nil, 5]
    assert_equal @back[nil, 5].sum, view.sum
    assert_equal SHAPE[0], @src.cells_requested
  end

  # A stepped slice still travels as one block request, with the step in it.
  def test_stepped_slice_asks_for_a_stepped_block
    view = @src[[(0..-1), 2], [(0..-1), 4]]
    assert_equal @back[[(0..-1), 2], [(0..-1), 4]].sum, view.sum
    assert_equal [[:copy_block, 32 * 24]], @src.log
  end

  # Transpose is not an order-preserving sub-region, so it falls to the
  # address list -- still only the cells the view covers.
  def test_transposed_slice_asks_for_its_addresses
    view = @src.transpose[0...10, 0...10]
    assert_equal @back.transpose[0...10, 0...10].sum, view.sum
    assert_equal [[:copy_addrs, 100]], @src.log
  end

  # The two paths over one view must agree on what they pull, which is the
  # asymmetry that made this hard to see from outside.
  def test_copy_and_reduce_make_the_same_request
    view = @src[8...24, 16...48]
    view.copy
    copy_log = @src.log.dup
    @src.log.clear
    view.sum
    assert_equal copy_log, @src.log
  end

  # --- values, across the kernel families that go through the iterator ---

  def test_values_agree_with_the_backing_array
    view = @src[8...24, 16...48]
    ref  = @back[8...24, 16...48]
    assert_equal ref.sum,             view.sum
    assert_equal ref.mean,            view.mean
    assert_equal ref.min,             view.min
    assert_equal ref.max,             view.max
    assert_equal ref.sum(axis: 0).to_a, view.sum(axis: 0).to_a
    assert_equal ref.sum(axis: 1).to_a, view.sum(axis: 1).to_a
    assert_equal ref.cumsum.to_a,     view.cumsum.to_a
    assert_equal ref.sort_index.to_a, view.sort_index.to_a
  end

  def test_values_agree_through_a_reshape
    view = @src[8...24, 16...48].reshape(32, 16)
    ref  = @back[8...24, 16...48].reshape(32, 16)
    assert_equal ref.sum(axis: 1).to_a, view.sum(axis: 1).to_a
  end

  # --- write side --------------------------------------------------------

  # In-place writes reach the view through ca_attach rather than the kernel
  # iterator, so they had the same escalation for the same reason one
  # subsystem over: ca_stride_func_attach attached the composed root.  A view
  # whose root has no memory to lend now owns its buffer, filled and drained
  # by region requests, and the root is never attached.
  class Writer < CAObject
    attr_reader :buf, :log

    def initialize(buf)
      @buf = buf
      @log = []
      super(CA_INT32, buf.shape)
    end

    private

    def fetch_addr(addr) = @buf[addr]
    def store_addr(addr, val) = @buf[addr] = val
    def copy_data(data) = data[] = @buf
    def sync_data(data) = @buf[] = data

    def copy_block(starts, counts, steps, data)
      @log << [:copy_block, counts.to_a.inject(:*)]
      data[] = @buf[*starts.each_index.map { |k| [starts[k], counts[k], steps[k]] }]
    end

    def sync_block(starts, counts, steps, data)
      @log << [:sync_block, counts.to_a.inject(:*)]
      @buf[*starts.each_index.map { |k| [starts[k], counts[k], steps[k]] }] = data
    end

    def copy_addrs(addrs, data) = data[] = @buf[addrs]
    def sync_addrs(addrs, data) = @buf[addrs] = data
  end

  def test_write_through_a_view_lands_in_the_view_only
    before = @back.copy
    dst    = Writer.new(@back.copy)

    dst[8...24, 16...48].map! { |x| x + 1 }

    assert_equal [[:copy_block, 16 * 32], [:sync_block, 16 * 32]], dst.log
    assert_equal (before[8...24, 16...48] + 1).to_a, dst.buf[8...24, 16...48].to_a
    assert_equal before[0...8, nil].to_a,  dst.buf[0...8, nil].to_a
    assert_equal before[nil, 0...16].to_a, dst.buf[nil, 0...16].to_a
  end

  # A bang operator takes the same route.
  def test_bang_operator_through_a_view_asks_only_for_the_region
    before = @back.copy
    dst    = Writer.new(@back.copy)

    dst[8...24, 16...48].add!(1)

    assert_equal [[:copy_block, 16 * 32], [:sync_block, 16 * 32]], dst.log
    assert_equal (before[8...24, 16...48] + 1).to_a, dst.buf[8...24, 16...48].to_a
    assert_equal before[0...8, nil].to_a, dst.buf[0...8, nil].to_a
  end

  # A contiguous slice cannot alias a root that holds no memory, so it takes
  # the region path too rather than borrowing a pointer into a materialised
  # root.  This is the case ca_attach_is_alias had to stop calling an alias.
  def test_contiguous_slice_cannot_alias_and_still_asks_for_its_region
    before = @back.copy
    dst    = Writer.new(@back.copy)

    dst[0...4, nil].add!(1)

    assert_equal [[:copy_block, 4 * 96], [:sync_block, 4 * 96]], dst.log
    assert_equal (before[0...4, nil] + 1).to_a, dst.buf[0...4, nil].to_a
    assert_equal before[8...12, nil].to_a, dst.buf[8...12, nil].to_a
  end

  # attach! hands the user a materialised buffer and commits it on exit; the
  # region is what gets fetched and what gets written back.
  def test_attach_bang_commits_the_region_only
    omit "requires CARRAY_DEV_BUILD (Ruby attach surface)" unless CArray.method_defined?(:attach!)
    before = @back.copy
    dst    = Writer.new(@back.copy)

    dst[0...4, 0...4].attach! { |inner| inner[] = 7 }

    assert_equal [[:copy_block, 16], [:sync_block, 16]], dst.log
    assert_equal [7], dst.buf[0...4, 0...4].to_a.flatten.uniq
    assert_equal before[0, 5], dst.buf[0, 5]
  end

  # Reads on a writable backing take the same region path as on a read-only
  # one -- the presence of the sync_* callbacks must not change the GET side.
  def test_reads_on_a_writable_backing_still_ask_for_the_region_only
    dst  = Writer.new(@back.copy)
    view = dst[8...24, 16...48]
    view.sum
    assert_equal [[:copy_block, 16 * 32]], dst.log
  end

  # --- the same shape one level down: a lazy CAMonOp root ----------------

  # ca_attach on a lazy transform view is the same cliff; the L2 path must
  # route around it too.  Values are the observable part here.
  def test_reduction_over_a_view_of_a_lazy_root
    raw  = CArray.int32(4000) { |i| i * 3 - 7 }
    lazy = raw.swap_bytes                  # CAMonOp
    ref  = raw.swap_bytes.copy             # same values, entity root
    assert_equal CAMonOp, lazy.class
    assert_equal ref[[100, 80]].reshape(20, 4).sum(axis: 1).to_a,
                 lazy[[100, 80]].reshape(20, 4).sum(axis: 1).to_a
    assert_equal ref[[100, 40]].sum, lazy[[100, 40]].sum
  end

  # --- index selection (CAGrid) over a root with no memory to lend ------

  ROWS = CA_INT64([3, 10, 40])
  COLS = CA_INT64([1, 5, 90])

  def test_index_selection_reads_ask_only_for_the_selected_cells
    view = @src[ROWS, COLS]
    assert_equal CAGrid, view.class
    { "sum"  => -> { assert_equal @back[ROWS, COLS].sum, view.sum },
      "copy" => -> { assert_equal @back[ROWS, COLS].to_a, view.copy.to_a },
      "mean(axis: 0)" => -> { assert_equal @back[ROWS, COLS].mean(axis: 0).to_a,
                                           view.mean(axis: 0).to_a } }.each do |name, check|
      @src.log.clear
      check.()
      assert_equal 9, @src.cells_requested, name
    end
  end

  # Logs whole and by-address requests too.
  class AddressWriter < Writer
    private
    def copy_data(data)
      @log << [:copy_data, data.elements]
      super
    end
    def sync_data(data)
      @log << [:sync_data, data.elements]
      super
    end
    def copy_addrs(addrs, data)
      @log << [:copy_addrs, addrs.elements]
      super
    end
    def sync_addrs(addrs, data)
      @log << [:sync_addrs, addrs.elements]
      super
    end
  end

  def test_index_selection_writes_land_in_the_selected_cells_only
    { "add!" => ->(v) { v.add!(1) },
      "map!" => ->(v) { v.map! { |x| x + 1 } } }.each do |name, op|
      dst = AddressWriter.new(@back.copy)
      op.(dst[ROWS, COLS])
      expected = @back.copy
      expected[ROWS, COLS] = expected[ROWS, COLS] + 1
      assert_equal expected.to_a, dst.buf.to_a, name
      assert_equal [[:copy_addrs, 3]] * 3 + [[:sync_addrs, 3]] * 3, dst.log, name
    end
  end

  # The other selections over the same root: a boolean selection
  # (CASelect), a boolean selection along an axis (CASelectAxis) and a
  # window with FILL bounds (CAWindow).
  def other_selections
    picked = CArray.boolean(*SHAPE) { 0 }
    picked[3, 1] = 1
    picked[10, 5] = 1
    picked[40, 90] = 1
    rows = CArray.boolean(SHAPE[0]) { 0 }
    rows[3] = 1
    rows[40] = 1
    { "CASelect"     => [->(a) { a[picked] }, 3],
      "CASelectAxis" => [->(a) { a[rows, nil] }, 2 * SHAPE[1]],
      "CAWindow"     => [->(a) { a.window([-2, 4], [90, 10]) }, 2 * 6] }
  end

  def test_other_selections_read_only_the_selected_cells
    other_selections.each do |name, (select, cells)|
      view = select.(@src)
      assert_equal name, view.class.name
      assert_equal select.(@back).sum, view.sum, name
      assert_equal cells, @src.cells_requested, name
      @src.log.clear
      assert_equal select.(@back).to_a, view.copy.to_a, name
      assert_equal cells, @src.cells_requested, name
      @src.log.clear
    end
  end

  def test_other_selections_write_only_the_selected_cells
    other_selections.each do |name, (select, _)|
      dst = AddressWriter.new(@back.copy)
      select.(dst).add!(1)
      expected = @back.copy
      select.(expected).add!(1)
      assert_equal expected.to_a, dst.buf.to_a, name
      assert_empty dst.log.select { |kind, _| kind == :copy_data || kind == :sync_data }, name
    end
  end

  def test_index_selection_over_a_lazy_root
    raw  = CArray.float64(40, 50) { |i| i * 0.5 }
    raw[7, 3] = UNDEF
    lazy = raw.lazy + 1.0
    ref  = raw + 1.0
    rows = CA_INT64([0, 7, 39])
    cols = CA_INT64([3, 3, 49])
    assert_equal ref[rows, cols].to_a, lazy[rows, cols].copy.to_a
    assert_equal ref[rows, cols].sum, lazy[rows, cols].sum
    assert_equal ref[rows, cols].sum(axis: 1).to_a, lazy[rows, cols].sum(axis: 1).to_a
  end
end
