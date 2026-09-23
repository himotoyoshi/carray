# spec_ai/test_address_basis.rb
#
# CArray::AddressBasis lends an addressing basis -- a pointer, and one byte
# stride per axis -- for the length of a block, to code that addresses cells
# itself.  It is a runtime facility at the ca_attach layer rather than a user
# surface; see guides/devel/21_address_basis.md.
#
# Three things are pinned here.
#
#   * Which of the three tiers an array lands in, and that each tier hands
#     back a basis the cells can actually be read and written through.
#   * That the block leaving by an exception still closes what was opened:
#     a tier-3 region is written back and freed rather than dropped.
#   * The packed form's buffer layout, which is a contract with whoever
#     decodes it -- in particular that an array with no mask still takes
#     one zero per axis of its own in the mask strides.
#
# Reading and writing through a raw address needs Fiddle, which is what a
# consumer of this surface uses anyway.

require "test/unit"
require "carray"
require "fiddle"

class TestAddressBasis < Test::Unit::TestCase

  AB = CArray::AddressBasis

  # --- reading and writing through a basis ------------------------------

  # The cell at `index` of a basis, as a packed string of `bytes` bytes.
  def cell (basis, index)
    offset = 0
    index.each_with_index { |i, k| offset += i * basis[:strides][k] }
    Fiddle::Pointer.new(basis[:pointer] + offset, basis[:bytes])[0, basis[:bytes]]
  end

  def read_int32 (basis, index)
    cell(basis, index).unpack1("l")
  end

  def write_int32 (basis, index, value)
    offset = 0
    index.each_with_index { |i, k| offset += i * basis[:strides][k] }
    Fiddle::Pointer.new(basis[:pointer] + offset, 4)[0, 4] = [value].pack("l")
  end

  # --- the arrays each tier is reached with ------------------------------

  def entity
    CArray.int32(4, 4).seq!
  end

  # A fold that reaches an entity: CATranspose over the entity.
  def stride_view (source = entity)
    source.transpose
  end

  # A fold that does not reach an entity: a CARefer over a CASelect stops at
  # the CASelect, which owns no memory to address.
  def xfer_view (source = entity)
    source[CArray.boolean(4, 4) { 1 }].reshape(4, 4)
  end

  # --- classify ---------------------------------------------------------

  def test_classify_tiers
    assert_equal AB::TIER_ENTITY, AB.classify(entity)[:tier]
    assert_equal AB::TIER_STRIDE, AB.classify(stride_view)[:tier]
    assert_equal AB::TIER_STRIDE, AB.classify(entity[1..2, nil])[:tier]
    assert_equal AB::TIER_STRIDE, AB.classify(entity.reshape(2, 8))[:tier]
    assert_equal AB::TIER_XFER,   AB.classify(entity[entity.ge(8)])[:tier]
  end

  # A CAStride whose fold stops short of an entity is not the stride tier:
  # addressing the root it lands on would mean attaching a view, and
  # detaching one throws the kernel's writes away.
  def test_classify_stride_family_that_does_not_fold_to_an_entity
    view = xfer_view
    assert_equal true,          AB.classify(view)[:stride_family]
    assert_equal AB::TIER_XFER, AB.classify(view)[:tier]
  end

  def test_classify_reports_the_array
    a = entity
    a[1, 1] = UNDEF
    report = AB.classify(a)
    assert_equal true,      report[:entity]
    assert_equal false,     report[:read_only]
    assert_equal true,      report[:masked]
    assert_equal [4, 4],    report[:dim]
    assert_equal 4,         report[:bytes]
    # the numeric data type, as the C side reads it
    assert_equal CArray.data_type_code(CA_INT32), report[:data_type]
  end

  def test_classify_reports_read_only
    a = entity.freeze
    assert_equal true, AB.classify(a)[:read_only]
  end

  # --- tier 1: the entity's own buffer ----------------------------------

  def test_entity_basis_is_the_buffer
    a = entity
    AB.open([a], [true]) do |bases|
      basis = bases.first
      assert_equal AB::TIER_ENTITY, basis[:tier]
      assert_equal [16, 4], basis[:strides]     # row major, in bytes
      assert_equal [4, 4],  basis[:dim]
      assert_equal 5,       read_int32(basis, [1, 1])
      write_int32(basis, [1, 1], 99)
    end
    assert_equal 99, a[1, 1]                    # written in place
  end

  # --- tier 2: the fold's root, addressed in place ----------------------

  def test_stride_basis_addresses_the_root_in_place
    a = entity
    t = a.transpose
    AB.open([t], [true]) do |bases|
      basis = bases.first
      assert_equal AB::TIER_STRIDE, basis[:tier]
      assert_equal [4, 16], basis[:strides]     # the transpose, folded
      assert_equal 4,       read_int32(basis, [0, 1])   # a[1, 0]
      write_int32(basis, [0, 1], 77)
    end
    assert_equal 77, a[1, 0]                    # no copy was made
  end

  # A view of a slice folds to the same root, with the base offset already
  # in the pointer.
  def test_stride_basis_of_a_slice
    a = entity
    AB.open([a[2..3, 1..2]], [false]) do |bases|
      basis = bases.first
      assert_equal AB::TIER_STRIDE, basis[:tier]
      assert_equal [16, 4], basis[:strides]
      assert_equal 9,  read_int32(basis, [0, 0])
      assert_equal 14, read_int32(basis, [1, 1])
    end
  end

  # --- tier 3: only the box crosses -------------------------------------

  def test_xfer_basis_carries_the_cells_and_writes_them_back
    a = entity
    view = xfer_view(a)
    AB.open([view], [true]) do |bases|
      basis = bases.first
      assert_equal AB::TIER_XFER, basis[:tier]
      assert_equal 5, read_int32(basis, [1, 1])
      write_int32(basis, [1, 1], 55)
    end
    assert_equal 55, a[1, 1]                    # scattered back on close
  end

  # The region is described per axis and only its cells move, in either
  # direction: the basis is shifted so the view's own coordinates still
  # address it, and the cells outside are left alone.
  def test_xfer_region_moves_only_what_was_asked_for
    a = entity
    view = xfer_view(a)
    AB.open([view], [true], [[1, 1]], [[2, 2]]) do |bases|
      basis = bases.first
      assert_equal [8, 4], basis[:strides]      # the box's own extents
      assert_equal 5,  read_int32(basis, [1, 1])
      assert_equal 10, read_int32(basis, [2, 2])
      write_int32(basis, [1, 1], 51)
      write_int32(basis, [2, 2], 52)
    end
    assert_equal [[0,  1,  2,  3],
                  [4, 51,  6,  7],
                  [8,  9, 52, 11],
                  [12, 13, 14, 15]], a.to_a
  end

  def test_xfer_region_outside_the_array_is_refused
    assert_raise(ArgumentError) do
      AB.open([xfer_view], [false], [[0, 0]], [[5, 4]]) { }
    end
  end

  def test_region_needs_one_start_and_one_count_per_axis
    assert_raise(ArgumentError) do
      AB.open([entity], [false], [[0]], [[1]]) { }
    end
  end

  def test_region_needs_both_halves
    assert_raise(ArgumentError) do
      AB.open([entity], [false], [[0, 0]], nil) { }
    end
  end

  def test_region_is_one_per_array
    assert_raise(ArgumentError) do
      AB.open([entity, entity], [false, false], [[0, 0]], [[1, 1]]) { }
    end
  end

  # --- masks ------------------------------------------------------------

  def test_mask_is_opened_alongside_its_array
    a = entity
    a[1, 1] = UNDEF
    AB.open([a], [false]) do |bases|
      basis = bases.first
      assert_not_nil basis[:mask_pointer]
      assert_equal [4, 1], basis[:mask_strides]   # one byte per mask cell
      marked = Fiddle::Pointer.new(basis[:mask_pointer] + 4 + 1, 1)[0, 1]
      assert_equal 1, marked.unpack1("C")
    end
  end

  def test_an_unmasked_array_reports_no_mask
    AB.open([entity], [false]) do |bases|
      assert_nil bases.first[:mask_pointer]
      assert_nil bases.first[:mask_strides]
    end
  end

  # A view that reinterprets the element size gets a mask of its own shape,
  # one cell of which covers a fraction of a parent cell.  Cells written
  # independently cannot express that, so it is refused rather than
  # marking a neighbour.
  def test_a_reinterpreting_view_with_a_mask_is_refused
    f = CArray.float64(4).seq!
    f[1] = UNDEF
    assert_raise(ArgumentError) do
      AB.open([f.refer(CA_INT32, [8])], [false]) { }
    end
  end

  # --- what is refused --------------------------------------------------

  def test_object_arrays_are_refused
    assert_raise(ArgumentError) { AB.open([CArray.object(4)], [false]) { } }
  end

  def test_a_read_only_array_is_refused_for_writing
    a = entity.freeze
    assert_raise(RuntimeError) { AB.open([a], [true]) { } }
    assert_nothing_raised { AB.open([a], [false]) { } }
  end

  def test_one_writable_flag_per_array
    assert_raise(ArgumentError) { AB.open([entity, entity], [true]) { } }
  end

  def test_something_that_is_not_an_array_is_refused
    assert_raise(TypeError) { AB.open([[1, 2, 3]], [false]) { } }
  end

  def test_no_arrays_is_no_bases
    AB.open([], []) { |bases| assert_equal [], bases }
  end

  # --- leaving by an exception ------------------------------------------

  # The block is run under rb_ensure, so a raise still closes every array
  # it opened.  Tier 3 is where that is visible from Ruby: its region is a
  # buffer of its own, and closing it is what sends the writes back.
  def test_a_raising_block_still_writes_a_region_back
    a = entity
    view = xfer_view(a)
    assert_raise(RuntimeError) do
      AB.open([view], [true]) do |bases|
        write_int32(bases.first, [1, 1], 41)
        raise "the kernel gave up"
      end
    end
    assert_equal 41, a[1, 1]
    assert_equal AB::TIER_XFER, AB.classify(view)[:tier]   # still usable
  end

  # Opening happens array by array, so a refusal part way through has to
  # close the ones already open.  The first array here is a tier-3 view
  # with a region buffer; the second is refused while being opened.
  def test_a_refusal_part_way_through_closes_what_was_opened
    a = entity
    view = xfer_view(a)
    f = CArray.float64(4).seq!
    f[1] = UNDEF
    assert_raise(ArgumentError) do
      AB.open([view, f.refer(CA_INT32, [8])], [true, false]) { }
    end
    # the first array is intact and can be opened again
    AB.open([view], [false]) do |bases|
      assert_equal 5, read_int32(bases.first, [1, 1])
    end
  end

  def test_a_block_that_is_not_given_is_still_a_closed_open
    assert_raise(LocalJumpError) { AB.open([xfer_view], [false]) }
  end

  # --- the region buffer is freed, not leaked ---------------------------

  # A tier-3 open mallocs the region; closing frees it.  The only way to
  # see that from Ruby is to watch the malloc zone across many calls.
  def bytes_per_call (script, setup = "")
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    prelude = <<~RUBY
      require "carray"
      require "fiddle"
      AB = CArray::AddressBasis
      whole = CArray.int32(1 << 14).seq!
      view = whole[CArray.boolean(1 << 14) { 1 }]   # 64 KB per open
      #{setup}
      begin
        stats = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      rescue LoadError, Fiddle::DLError
        exit 2
      end
      in_use = -> {
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        stats.call(nil, buf)
        buf[8, 8].unpack1("Q")            # malloc_statistics_t#size_in_use
      }
      call = -> { (#{script}) rescue nil }
      50.times { call.() }
      GC.start
      before = in_use.()
      200.times { call.() }
      GC.start
      puts (in_use.() - before).fdiv(200)
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", prelude], &:read)
    omit "measurement unavailable" if $?.exitstatus == 2
    assert $?.success?, "measuring process failed"
    Float(out)
  end

  def assert_frees_the_region (script, setup = "")
    grown = bytes_per_call(script, setup)
    assert_operator grown, :<, 4096,
                    "#{script}: the malloc zone grew #{grown.round} bytes per call"
  end

  def test_a_completed_open_frees_the_region
    assert_frees_the_region("AB.open([view], [false]) { }")
  end

  def test_a_raising_open_frees_the_region
    assert_frees_the_region("AB.open([view], [false]) { raise 'boom' }")
  end

  # The refusal part way through, measured: the region opened for the first
  # array is freed even though the second array never opened.
  def test_a_refusal_part_way_through_frees_the_region
    assert_frees_the_region("AB.open([view, bad], [false, false]) { }", <<~SETUP)
      f = CArray.float64(4).seq!
      f[1] = UNDEF
      bad = f.refer(CA_INT32, [8])
    SETUP
  end

  # --- the packed form --------------------------------------------------
  #
  # The layout written out in guides/devel/21_address_basis.md.  Four
  # buffers: count pointers, the strides concatenated, count mask pointers,
  # the mask strides concatenated.

  def test_packed_yields_four_buffers
    a = CArray.int32(2, 3).seq!
    b = CArray.float64(4).seq!
    AB.open([a, b], [false, false], nil, nil, true) do |ptrs, strs, mptrs, mstrs|
      assert_equal 2 * 8, ptrs.bytesize
      assert_equal 2 * 8, mptrs.bytesize
      assert_equal 3 * 8, strs.bytesize          # 2 axes + 1 axis
      assert_equal 3 * 8, mstrs.bytesize         # one slot per data axis
      assert_equal [12, 4, 8], strs.unpack("q*")
    end
  end

  # A pointer in the packed form is the same address the hash form reports.
  def test_packed_pointers_address_the_same_cells
    a = CArray.int32(2, 3).seq!
    AB.open([a], [false], nil, nil, true) do |ptrs, strs, _, _|
      pointer = ptrs.unpack1("Q")
      strides = strs.unpack("q*")
      offset  = 1 * strides[0] + 2 * strides[1]
      assert_equal 5, Fiddle::Pointer.new(pointer + offset, 4)[0, 4].unpack1("l")
    end
  end

  # The one part of the layout that cannot be guessed: an array with no
  # mask still takes its slots in the mask strides -- one per axis of its
  # own, zero -- so that the mask strides of the arrays after it stay where
  # the reader expects them.
  def test_an_unmasked_array_takes_zero_slots_of_its_own_rank
    grid = CArray.int32(3, 4).seq!            # rank 2, no mask
    row  = CArray.int32(4).seq!               # rank 1, masked
    row[2] = UNDEF
    AB.open([grid, row], [false, false], nil, nil, true) do |ptrs, _, mptrs, mstrs|
      assert_equal 2 * 8, ptrs.bytesize
      mask_pointers = mptrs.unpack("Q*")
      assert_equal 0, mask_pointers[0]        # no mask: a zero pointer
      assert_not_equal 0, mask_pointers[1]
      strides = mstrs.unpack("q*")
      assert_equal 3, strides.length          # 2 for the grid, 1 for the row
      assert_equal [0, 0], strides[0, 2]      # the grid's own rank, zeroed
      assert_equal [1],    strides[2, 1]      # the row's mask, one byte a cell
    end
  end

  def test_packed_writes_are_sent_back
    a = entity
    view = xfer_view(a)
    AB.open([view], [true], nil, nil, true) do |ptrs, strs, _, _|
      pointer = ptrs.unpack1("Q")
      strides = strs.unpack("q*")
      offset  = 2 * strides[0] + 3 * strides[1]
      Fiddle::Pointer.new(pointer + offset, 4)[0, 4] = [33].pack("l")
    end
    assert_equal 33, a[2, 3]
  end

  def test_packed_closes_on_a_raise
    a = entity
    view = xfer_view(a)
    assert_raise(RuntimeError) do
      AB.open([view], [true], nil, nil, true) do |ptrs, strs, _, _|
        offset = 2 * strs.unpack("q*")[0]
        Fiddle::Pointer.new(ptrs.unpack1("Q") + offset, 4)[0, 4] = [22].pack("l")
        raise "the kernel gave up"
      end
    end
    assert_equal 22, a[2, 0]
  end
end
