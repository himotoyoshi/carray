require "test/unit"
require "carray"
require "objspace"

# Cross-cutting tests for the CAStride family
# (CARefer / CABlock / CATranspose / CAFarray / CARepeat).
#
# These target the "suspicious" areas of the Phase B/D/R/C/E migration:
# - subclass identity preservation across .dup / .clone / iteration
# - tail-bearing subclass invariants (mask0 ownership for CARefer,
#   base_offset <-> start[] sync for CABlock)
# - alias-attach correctness (write-through to parent, no double-free)
# - CARefer byte-reinterpret mask chains (CARepeat / CAReduce
#   intermediates)
# - value_array mask strip
# - cross-subclass composition (CABlock of CATranspose etc.)
# - CAStride accessors visible through every subclass
# - read-only flag propagation in CARepeat

class TestCAStrideFamilyHierarchy < Test::Unit::TestCase
  # Every strided-view subclass should be a CAStride and therefore a
  # CAView / CArray.  Regression target: someone redefines a
  # subclass with the wrong parent.
  def test_class_hierarchy
    [CARefer, CABlock, CATranspose, CAFarray, CARepeat].each do |klass|
      assert_operator(klass, :<, CAStride,
                      "#{klass} should subclass CAStride")
      assert_operator(klass, :<, CAView,
                      "#{klass} should subclass CAView transitively")
      assert_operator(klass, :<, CArray,
                      "#{klass} should subclass CArray transitively")
    end
  end

  def test_subclass_instance_isa_castride
    src = CArray.float64(4, 5).seq
    instances = {
      "CARefer (reshape)" => src.refer,
      "CABlock"           => src[1..2, nil],
      "CATranspose"       => src.transpose,
      "CAFarray"          => src.farray,
      "CARepeat"          => CArray.float64(3).seq[4, :%],
    }
    instances.each do |name, obj|
      assert_kind_of(CAStride, obj, "#{name} should be a CAStride")
      assert_kind_of(CAView, obj, "#{name} should be a CAView")
    end
  end

  def test_castride_accessors_work_on_subclasses
    src = CArray.float64(4, 5).seq
    [
      src.refer,
      src[1..2, nil],
      src.transpose,
      src.farray,
      CArray.float64(3).seq[4, :%],
    ].each do |view|
      assert_kind_of(Array, view.strides,
                     "#{view.class}#strides should return Array")
      assert_equal(view.ndim, view.strides.length,
                   "#{view.class}#strides length should equal ndim")
      assert_kind_of(Integer, view.byte_offset,
                     "#{view.class}#byte_offset should return Integer")
    end
  end
end

class TestCAStrideFamilyDupIdentity < Test::Unit::TestCase
  # dup must preserve subclass identity (covers both pure-typedef
  # subclasses and tail-bearing ones).
  def test_dup_preserves_class_pure_typedef
    src = CArray.float64(4, 5).seq
    [src.transpose, src.farray, CArray.float64(3).seq[4, :%]].each do |view|
      d = view.dup
      assert_equal(view.class, d.class,
                   "#{view.class}#dup should produce the same class")
      assert_equal(view.to_a, d.to_a,
                   "#{view.class}#dup should preserve data")
    end
  end

  def test_dup_preserves_class_tail_bearing
    src = CArray.float64(4, 5).seq
    [src.refer, src[1..2, 1..3]].each do |view|
      d = view.dup
      assert_equal(view.class, d.class,
                   "#{view.class}#dup should produce the same class")
      assert_equal(view.to_a, d.to_a,
                   "#{view.class}#dup should preserve data")
    end
  end

  def test_dup_of_deformed_refer_preserves_data
    # Byte-reinterpret CARefer should round-trip cleanly through dup.
    u32 = CArray.uint32(2).tap { |__a| __a[] = [0x01020304, 0x05060708] }
    split = u32.refer(:uint8, [8])
    d = split.dup
    assert_equal(CARefer, d.class)
    assert_equal(split.to_a, d.to_a)
  end
end

class TestCABlockTailSync < Test::Unit::TestCase
  # CABlock keeps both base_offset (CAStride prefix) and start[] (tail);
  # any in-place mutation of start[] must be followed by a base_offset
  # recompute or gather reads from the wrong region of parent memory.

  def test_block_iterator_moves_correctly
    # CABlockIterator is constructed via CArray#blocks(range).
    # Phase E iterator update: kernel start[] mutation followed by
    # ca_block_sync_base_offset.  Without the sync, the gathered
    # values would be wrong.
    src = CArray.int32(6).seq        # [0, 1, 2, 3, 4, 5]
    iter = src.blocks(0..1)
    results = []
    iter.each { |blk| results << blk.to_a }
    assert_equal([[0, 1], [2, 3], [4, 5]], results,
                 "CABlockIterator should iterate over consecutive blocks")
  end

  def test_slab_iterator_collects_rows
    # SI.3: CASlabIterator.  :> marks the slab (kernel) axis; axis 0 is the
    # outer iteration space.  The yielded slab is the 1-D row directly.
    src = CArray.int32(3, 4).seq
    rows = []
    src[nil, :>].each { |row| rows << row.to_a }
    assert_equal([[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], rows,
                 "CASlabIterator should walk all 3 rows in order")
  end
end

class TestCABlockMaskIsCABlock < Test::Unit::TestCase
  # After Phase E, CABlock's mask is itself a CABlock (custom
  # create_mask).  Verify that this stays true so iterator code that
  # casts kernel->mask to (CABlock *) keeps working.
  def test_mask_class_is_cablock
    src = CArray.float64(10).seq
    src.mask = CArray.boolean(10).tap { |i| i[] = i == 3 ? 1 : 0 }
    blk = src[2..6]
    assert_kind_of(CABlock, blk.mask,
                   "CABlock's mask should be a CABlock instance")
  end
end

class TestCAReferDeformedMaskChain < Test::Unit::TestCase
  # CARefer with bytes != parent.bytes builds its mask through a
  # CARepeat (divided) or CAReduce (spanned) intermediate stored as
  # mask0.  Test that mask values are correct and that GC doesn't free
  # the intermediate prematurely.
  def test_divided_mask_broadcasts
    # parent has mask on one of 2 elements -> view sees mask repeated
    # over its 4 sub-positions for the masked parent element.
    u32 = CArray.uint32(2).tap { |__a| __a[] = [0x01020304, 0x05060708] }
    u32.mask = [0, 1]
    split = u32.refer(:uint8, [8])
    # parent[0] (uint32) unmasked, parent[1] masked -> view bytes
    # 0..3 unmasked, view bytes 4..7 masked.
    assert_equal([false, false, false, false, true, true, true, true], split.is_masked.to_a)
  end

  def test_spanned_mask_builds_chain
    # Spanned CARefer's mask is built through a CAReduce intermediate
    # (mask0).  Any masked parent byte in a reduction group should
    # mask the corresponding view element.
    8.times do |k|
      u8 = CArray.uint8(8).seq
      mask = [0] * 8; mask[k] = 1
      u8.mask = mask
      v32 = u8.refer(:uint32, [2])
      expected = [k < 4 ? true : false, k < 4 ? false : true]
      assert_equal(expected, v32.is_masked.to_a,
                   "spanned: mask on byte #{k} should mask view[#{k/4}]")
    end
    # Mask must actually be a CARefer (Phase C invariant: mask of a
    # CARefer is a CARefer).
    u8 = CArray.uint8(8).seq
    u8.mask = [0, 1, 0, 0, 0, 0, 0, 0]
    assert_kind_of(CARefer, u8.refer(:uint32, [2]).mask)
  end

  def test_divided_mask_survives_gc
    u32 = CArray.uint32(4).seq
    u32.mask = [0, 1, 0, 1]
    split = u32.refer(:uint8, [16])
    # Force the mask chain to be built and then trigger GC.
    _ = split.is_masked.to_a
    GC.start
    # mask0 (the CARepeat) must still be alive; second access must
    # produce the same answer.
    assert_equal([false]*4 + [true]*4 + [false]*4 + [true]*4, split.is_masked.to_a,
                 "divided mask intermediate must survive GC")
  end
end

class TestCAReferValueArray < Test::Unit::TestCase
  # ca.value is a CARefer with CA_FLAG_VALUE_ARRAY set.  The mask
  # auto-propagated by ca_stride_setup must be stripped, otherwise
  # value-array semantics break.
  def test_value_array_has_no_mask
    src = CArray.int32(3).seq
    src.mask = [1, 0, 0]
    val = src.value
    assert_kind_of(CARefer, val)
    assert_false(val.has_mask?,
                 "ca.value should not carry a mask")
  end

  def test_value_array_reads_through_mask
    src = CArray.int32(5).seq
    src.mask = [1, 0, 1, 0, 1]
    val = src.value
    # All values should be readable regardless of original mask.
    assert_equal([0, 1, 2, 3, 4], val.to_a)
  end
end

class TestCAStrideAliasAttach < Test::Unit::TestCase
  # Contiguous strided views alias parent->ptr at attach time
  # instead of allocating + gathering.  Test correctness, not perf.
  def test_alias_write_through_to_parent
    src = CArray.float64(1000).seq
    view = src.refer    # contig: should alias
    view.attach! do |v|
      v[0] = -1.0
      v[999] = -2.0
    end
    assert_equal(-1.0, src[0])
    assert_equal(-2.0, src[999])
  end

  def test_alias_block_row_slice
    # CABlock row slice is contiguous => alias path.
    src = CArray.float64(10, 10).seq
    row_blk = src[1..3, nil]
    row_blk.attach! do |b|
      b[0, 0] = 99.0
    end
    assert_equal(99.0, src[1, 0],
                 "alias-attach write to row block should land in parent")
  end

  def test_non_contig_attach_still_works
    # Column slice is NOT contig -> gather/scatter path.
    src = CArray.float64(4, 4).seq
    col_blk = src[nil, 1..2]
    col_blk.attach! do |b|
      b[0, 0] = 77.0
    end
    assert_equal(77.0, src[0, 1])
  end

  def test_alias_detach_no_double_free
    # Repeated attach/detach cycles must not double-free the aliased
    # pointer.  If they did, this would crash quickly.
    src = CArray.float64(100).seq
    view = src.refer
    50.times { view.attach! { |_| } }
    GC.start
    assert_equal(50.0, src[50])   # data still readable
  end

  def test_byte_reinterpret_aliases_too
    # Divided CARefer is contiguous in byte terms -> still aliases.
    u32 = CArray.uint32(2).tap { |__a| __a[] = [0x01020304, 0x05060708] }
    split = u32.refer(:uint8, [8])
    split.attach! do |v|
      v[0] = 0xff
    end
    # On little-endian, byte 0 of u32[0] is the low byte (0x04 ->
    # 0xff).  Result: u32[0] = 0x010203FF.
    assert_equal(0x010203ff, u32[0],
                 "byte-reinterpret view write should alias-write to parent")
  end
end

class TestCAStrideCompose < Test::Unit::TestCase
  # Composition of strided views: CARefer of CATranspose, CABlock of
  # CARepeat, etc.  The CAStride alias-attach path should handle
  # multi-level parent chains.
  def test_block_of_transposed
    src = CArray.int32(3, 4).seq    # row-major [0..11]
    tr = src.transpose             # shape (4, 3)
    # Take a row of the transposed view => CABlock on CATranspose.
    blk = tr[1, nil]
    assert_equal([1, 5, 9], blk.to_a)
  end

  def test_refer_of_transposed
    src = CArray.int32(3, 4).seq
    tr = src.transpose             # (4, 3)
    re = tr.refer(:int32, [12])     # flatten the transposed view
    # The flattened transpose is the column-major read of src.
    expected = (0...12).map { |k| src[k % 3, k / 3] }
    assert_equal(expected, re.to_a)
  end

  def test_transposed_of_block
    src = CArray.int32(4, 4).seq
    blk = src[1..2, 1..2]           # 2x2 sub-block
    trb = blk.transpose
    assert_equal(blk.to_a.transpose, trb.to_a)
  end
end

class TestCARepeatReadOnly < Test::Unit::TestCase
  # CARepeat must propagate CA_FLAG_READ_ONLY (the gather buffer would
  # otherwise scatter back to overlapping parent positions ambiguously).
  def test_repeat_view_is_read_only
    src = CArray.float64(3).seq
    rep = src[4, :%]
    assert_true(rep.read_only?)
    assert_raise { rep[0, 0] = 99.0 }
  end

  def test_repeat_mask_is_read_only
    src = CArray.float64(3).seq
    src.mask = [0, 1, 0]
    rep = src[4, :%]
    assert_true(rep.read_only?)
    # mask should also be read-only (was the case in the original
    # CARepeat; preserved in Phase R)
    assert_true(rep.mask.read_only?,
                "CARepeat's mask should also be read-only")
  end

  def test_repeat_copy_materialises_independent_buffer
    src = CArray.float64(3).seq
    rep = src[4, :%]
    copy = rep.copy
    # copy should be writable and independent of src
    copy[0, 0] = 99.0
    assert_equal(0.0, src[0],
                 "copy should produce an independent buffer")
  end
end

class TestCAStrideNegativeStrides < Test::Unit::TestCase
  # `ca_stride_is_contiguous` must return false for views with
  # negative strides; otherwise the alias-attach fast path would
  # alias the wrong region of parent memory.
  def test_negative_stride_view_does_not_alias_but_works
    src = CArray.float64(10).seq
    rev = src.as_strided(shape: [10], strides: [-8], offset: 72)
    assert_equal((0..9).to_a.reverse.map(&:to_f), rev.to_a,
                 "negative-stride view should read parent in reverse")
    # Write-through still works through the gather/scatter path.
    rev[0] = -1.0      # parent's last element
    assert_equal(-1.0, src[9],
                 "negative-stride view write must scatter to parent")
  end

  def test_negative_stride_2d_reverse_rows
    src = CArray.float64(3, 4).seq
    bytes = 8
    n = 4
    rev = src.as_strided(shape: [3, 4],
                         strides: [-n*bytes, bytes],
                         offset: 2*n*bytes)
    # Reverses the row order: rows [2, 1, 0]
    assert_equal([src[2,nil].to_a, src[1,nil].to_a, src[0,nil].to_a],
                 rev.to_a)
  end
end

class TestCAStrideMemoryViewBoundaries < Test::Unit::TestCase
  # Phase C replaced `cr->is_deformed != 0 && != 1` with
  # `ca->bytes != parent->bytes` in carray_memory_view.c.  The two
  # conditions should give the same boundary: simple reshape passes,
  # byte reinterpret rejects.
  def test_simple_reshape_refer_is_exportable
    u32 = CArray.uint32(2).seq
    re  = u32.refer(:uint32, [2])
    assert_true(CArray.memory_view_available?(re),
                "simple CARefer reshape should be MV-exportable")
  end

  def test_byte_reinterpret_refer_is_exportable_over_entity
    # CARefer with bytes != parent.bytes is a byte-reinterpret view.
    # As long as parent is an entity (or alias-chain to entity) and
    # the new data_type has a valid MV format, the view is just a
    # contig strided view of parent memory with a different format.
    u32 = CArray.uint32(2).seq
    split = u32.refer(:uint8, [8])              # uint32 -> uint8 (divided)
    assert_true(CArray.memory_view_available?(split),
                "divided CARefer over entity should be MV-exportable")

    spanned_src = CArray.uint8(8).seq
    spanned = spanned_src.refer(:uint32, [2])   # uint8 -> uint32 (spanned)
    assert_true(CArray.memory_view_available?(spanned),
                "spanned CARefer over entity should be MV-exportable")
  end

  def test_raw_castride_is_exportable
    # CAStride created directly via #as_strided -- the base class --
    # must be MV-exportable.  Otherwise every CAStride subclass would
    # export while as_strided users wouldn't, which would be a
    # surprise.
    src = CArray.float64(4, 5).seq
    bytes = 8
    contig = src.as_strided(shape: [4, 5],
                            strides: [5 * bytes, bytes], offset: 0)
    assert_true(CArray.memory_view_available?(contig),
                "fully-contiguous CAStride should be MV-exportable")

    transposed_like = src.as_strided(shape: [5, 4],
                                     strides: [bytes, 5 * bytes],
                                     offset: 0)
    assert_true(CArray.memory_view_available?(transposed_like),
                "strided CAStride (transpose pattern) should be MV-exportable")
  end
end

class TestCABlockStepKernel < Test::Unit::TestCase
  # CABlock with non-unit step exercises a code path that
  # ca_block_sync_base_offset shouldn't break (the step doesn't
  # appear in the base_offset formula directly; only Σ start[k] *
  # Π size0[j] does).
  def test_block_with_step_reads_strided_parent
    src = CArray.int32(10).seq
    blk = src[[0, 5, 2]]       # start=0 count=5 step=2 -> [0, 2, 4, 6, 8]
    assert_kind_of(CABlock, blk)
    assert_equal([2], blk.step)
    assert_equal([5], blk.count)
    assert_equal([0, 2, 4, 6, 8], blk.to_a)
  end

end

class TestCAStrideDeepChain < Test::Unit::TestCase
  # 4-deep virtual chain: every link is a CAStride subclass.
  # Tests cascading attach/detach and that intermediate views' data
  # propagates end-to-end.
  def test_four_level_chain_reads
    src = CArray.int32(4, 5).seq
    chain = src.transpose              # CATranspose, shape (5, 4)
                .refer(:int32, [20])    # CARefer reshape
                .refer(:int32, [4, 5])  # another reshape
    # The composition isn't src itself -- transpose changes order --
    # but it must be readable end-to-end without crashing.
    assert_equal([4, 5], chain.shape)
    flat = src.transpose.to_a.flatten
    assert_equal(flat.each_slice(5).to_a, chain.to_a)
  end

  def test_chain_attach_detach_no_leak
    src = CArray.int32(10, 10).seq
    20.times do
      chain = src[1..8, 1..8].transpose.refer(:int32, [64])
      _ = chain.to_a
    end
    GC.start
    # If detach leaked or freed the wrong pointer, GC.start after
    # many transient chains would crash; reaching here is the
    # assertion.
    assert(true)
  end
end

class TestCAStrideReentrantAttach < Test::Unit::TestCase
  # attach! is documented as scope-strict; the harness must tolerate
  # re-entrant attach on the same object (inner attach sees the
  # outer's buffer rather than allocating a new one).
  def test_nested_attach_bang
    src = CArray.float64(5).seq
    src.attach! do
      src.attach! do
        src[0] = -1.0
      end
    end
    assert_equal(-1.0, src[0])
  end

  def test_nested_attach_bang_on_view
    src = CArray.float64(10).seq
    view = src.refer
    view.attach! do
      view.attach! do
        view[0] = -7.0
      end
    end
    assert_equal(-7.0, src[0],
                 "nested attach! on aliased view must still write through")
  end
end

class TestCAStrideFrozen < Test::Unit::TestCase
  # A view of a frozen parent should refuse writes, whether the
  # write goes through the alias-attach fast path or the gather/
  # scatter slow path.
  def test_write_through_frozen_parent_aliased
    src = CArray.float64(5).seq.freeze
    re = src.refer                       # contig => aliases
    assert_raise(FrozenError) { re[0] = -1.0 }
  end

  def test_write_through_frozen_parent_strided
    src = CArray.float64(3, 4).seq.freeze
    col = src[nil, 1]                    # non-contig column slice
    assert_raise(FrozenError) { col[0] = -1.0 }
  end
end

class TestCAStrideMemsize < Test::Unit::TestCase
  # dsize callbacks must report > 0 (basic sanity that the
  # typeddata's dsize is wired up correctly for every subclass).
  def test_memsize_of_each_subclass_is_positive
    src = CArray.float64(3, 4).seq
    cases = {
      "CArray (entity)" => src,
      "CARefer"         => src.refer,
      "CABlock"         => src[1..2, nil],
      "CATranspose"     => src.transpose,
      "CAFarray"        => src.farray,
      "CARepeat"        => CArray.float64(3).seq[4, :%],
    }
    cases.each do |name, obj|
      sz = ObjectSpace.memsize_of(obj)
      assert_operator(sz, :>, 0,
                      "memsize_of(#{name}) should be positive, got #{sz}")
    end
  end
end

class TestCAFarrayScalarParent < Test::Unit::TestCase
  # CAFarray's setup preserves CA_FLAG_SCALAR when parent is a
  # CScalar (preserved verbatim through the Phase D migration).
  def test_scalar_flag_propagated
    s = CScalar.float64
    s[0] = 3.14
    fa = s.farray
    assert_kind_of(CAFarray, fa)
    assert_true(fa.scalar?,
                "CAFarray of a scalar parent should be flagged scalar")
    assert_equal([3.14], fa.to_a)
  end
end

class TestCAStrideSetupConsistency < Test::Unit::TestCase
  # After construction, base_offset and strides should give the same
  # answer as the public Ruby API.  Cross-check using #idx2addr0 for
  # CABlock and direct comparison for the others.
  def test_block_idx2addr0_matches_strides
    src = CArray.float64(5, 6).seq
    blk = src[1..3, 2..4]
    # block.idx2addr0(i, j) returns the parent flat-element address.
    # base_offset / bytes + sum(idx * strides[k] / bytes) should equal
    # the same thing.
    bytes = blk.bytes
    blk.shape[0].times do |i|
      blk.shape[1].times do |j|
        expected = blk.idx2addr0(i, j)
        actual = blk.byte_offset / bytes +
                 i * blk.strides[0] / bytes +
                 j * blk.strides[1] / bytes
        assert_equal(expected, actual,
                     "idx2addr0(#{i},#{j}) should match strides+offset")
      end
    end
  end

  def test_transpose_strides_are_inverted
    src = CArray.float64(3, 4)
    tr = src.transpose
    # parent strides (in element units) are (4, 1); view strides
    # (in bytes) should be (1*bytes, 4*bytes) = (8, 32).
    assert_equal([8, 32], tr.strides)
    assert_equal(0, tr.byte_offset)
  end

  def test_farray_strides_are_reversed
    src = CArray.float64(2, 3, 4)
    fa = src.farray
    # parent byte strides: (3*4*8, 4*8, 8) = (96, 32, 8)
    # view dim = reversed parent dim, view strides = reversed parent strides
    assert_equal([8, 32, 96], fa.strides)
    assert_equal(0, fa.byte_offset)
  end

  def test_repeat_has_zero_strides_for_repeat_axes
    src = CArray.float64(3).seq
    rep = src[4, :%]
    # axis 0 is the repeat axis (count=4); axis 1 is the data axis.
    assert_equal([0, 8], rep.strides,
                 "repeat axis should have stride 0")
  end
end
