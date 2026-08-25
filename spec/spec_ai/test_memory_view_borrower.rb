require "test/unit"
require "carray"

# This test exercises the end-to-end MemoryView protocol path by calling
# rb_memory_view_get from a tiny C borrower extension and asserting that
# the data, shape, and strides are correct.
#
# To build the borrower extension:
#   cd spec_ai/ext_memory_view_test && ruby extconf.rb && make
#
# If the extension isn't built, this test file is skipped.

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_memory_view_borrower: mv_borrower.bundle not built."
  warn "Build it with: (cd #{borrower_dir} && ruby extconf.rb && make)"
  return
end

class TestMemoryViewBorrower < Test::Unit::TestCase

  STRIDES = MVBorrower::STRIDES

  # ---------- Phase 1: entity arrays ----------

  def test_entity_int32_data_and_strides
    ca = CArray.int32(3, 4).seq
    v = MVBorrower.inspect_view(ca, STRIDES)
    assert_not_nil(v)
    assert_equal([3, 4], v[:shape])
    assert_equal([16, 4], v[:strides])
    assert_equal(48, v[:byte_size])
    assert_equal(4, v[:item_size])
    assert_equal("i", v[:format])
    assert_equal(false, v[:readonly])
    assert_true(v[:row_major])
    # Verify data bytes match the array contents.
    expected = (0...12).map { |i| [i].pack("l") }.join
    assert_equal(expected, v[:data])
  end

  def test_entity_float64_data
    ca = CArray.float64(2, 3).seq(0.5, 1.5)   # 0.5, 2.0, 3.5, 5.0, 6.5, 8.0
    v = MVBorrower.inspect_view(ca, STRIDES)
    assert_equal("d", v[:format])
    assert_equal([2, 3], v[:shape])
    assert_equal([24, 8], v[:strides])
    expected = [0.5, 2.0, 3.5, 5.0, 6.5, 8.0].pack("d6")
    assert_equal(expected, v[:data])
  end

  def test_scalar_view
    cs = CScalar.new(CA_INT32)
    cs[] = 12345
    v = MVBorrower.inspect_view(cs, STRIDES)
    assert_equal(0, v[:ndim])
    assert_equal(4, v[:byte_size])
    assert_equal(4, v[:item_size])
    assert_equal([12345].pack("l"), v[:data])
  end

  def test_refer_reshape_data_matches
    ca = CArray.int32(12).seq
    rf = ca.reshape(3, 4)
    v = MVBorrower.inspect_view(rf, STRIDES)
    assert_equal([3, 4], v[:shape])
    assert_equal([16, 4], v[:strides])
    expected = (0...12).map { |i| [i].pack("l") }.join
    assert_equal(expected, v[:data])
  end

  # ---------- Phase 2: strided virtual arrays ----------

  def test_block_contiguous_subset
    ca = CArray.int32(4, 5).seq    # rows of 5 elements each
    bl = ca[1..2, 1..3]            # a 2x3 sub-block
    assert_equal(CA_OBJ_BLOCK, bl.obj_type)
    v = MVBorrower.inspect_view(bl, STRIDES)
    assert_equal([2, 3], v[:shape])
    # Block stride dim 0 = step[0] * size0[1] * bytes = 1 * 5 * 4 = 20
    # Block stride dim 1 = step[1] * 1 * bytes = 4
    assert_equal([20, 4], v[:strides])
    # PEP 3118 convention: byte_size = product(shape) * item_size
    # = 2 * 3 * 4 = 24 (NOT the strided span; consumers that need the
    # addressable range compute it themselves from shape+strides).
    assert_equal(24, v[:byte_size])
    # The data buffer is the parent's full buffer; verify the block
    # values are at the expected strided positions.
    base_addr = 1 * 5 + 1   # start[0]=1, start[1]=1
    # Materialise expected: row r, col c -> parent[1+r, 1+c] = (1+r)*5 + (1+c)
    expected_values = (0...2).flat_map { |r| (0...3).map { |c| (1 + r) * 5 + (1 + c) } }
    # Extract by stride from v[:data]
    bytes_per = 4
    actual_values = expected_values.each_with_index.map { |_, i|
      r = i / 3
      c = i % 3
      off = (base_addr * bytes_per - base_addr * bytes_per) + r * v[:strides][0] + c * v[:strides][1]
      # off should be relative to the data pointer in the borrowed view
      v[:data][off, bytes_per].unpack1("l")
    }
    assert_equal(expected_values, actual_values)
  end

  def test_block_stepped_is_strided
    ca = CArray.int32(10).seq
    # Take every other element: positions 0, 2, 4, 6, 8
    bl = ca[[0, 5, 2]]
    assert_equal(CA_OBJ_BLOCK, bl.obj_type)
    v = MVBorrower.inspect_view(bl, STRIDES)
    assert_equal([5], v[:shape])
    # stride = step * bytes = 2 * 4 = 8
    assert_equal([8], v[:strides])
    values = (0...5).map { |i| v[:data][i * v[:strides][0], 4].unpack1("l") }
    assert_equal([0, 2, 4, 6, 8], values)
  end

  def test_farray_column_major
    # parent is row-major: parent[i,j] = i*3 + j  (i=0..1, j=0..2)
    ca = CArray.int32(2, 3).seq
    fa = ca.farray
    assert_equal(CA_OBJ_FARRAY, fa.obj_type)
    v = MVBorrower.inspect_view(fa, STRIDES | MVBorrower::COLUMN_MAJOR)
    assert_not_nil(v, "CAFarray must be exportable with COLUMN_MAJOR flag")
    # CAFarray dim is reversed from parent: (2,3) -> (3,2)
    assert_equal([3, 2], v[:shape])
    # Column-major: strides = [bytes, dim[0]*bytes] = [4, 12]
    assert_equal([4, 12], v[:strides])
    assert_true(v[:col_major])
    assert_false(v[:row_major])
    # fa[i,j] is parent[j,i] = j*3 + i
    expected = (0...3).flat_map { |i| (0...2).map { |j| j * 3 + i } }
    actual = expected.each_with_index.map { |_, n|
      i = n / 2; j = n % 2
      off = i * v[:strides][0] + j * v[:strides][1]
      v[:data][off, 4].unpack1("l")
    }
    assert_equal(expected, actual)
  end

  def test_transpose_permutes_strides
    # parent[i,j] = i*3 + j  (i=0..1, j=0..2)
    ca = CArray.int32(2, 3).seq
    tr = ca.transpose
    assert_equal(CA_OBJ_TRANSPOSE, tr.obj_type)
    v = MVBorrower.inspect_view(tr, STRIDES)
    # transposed shape is [3, 2]
    assert_equal([3, 2], v[:shape])
    # parent_strides = [3*4=12, 4]; imap = [1, 0] -> [parent[1], parent[0]] = [4, 12]
    assert_equal([4, 12], v[:strides])
    # tr[i,j] = ca[j,i] = j*3 + i
    expected = (0...3).flat_map { |i| (0...2).map { |j| j * 3 + i } }
    actual = expected.each_with_index.map { |_, n|
      i = n / 2; j = n % 2
      off = i * v[:strides][0] + j * v[:strides][1]
      v[:data][off, 4].unpack1("l")
    }
    assert_equal(expected, actual)
  end

  # ---------- writable: writing into a CABlock view modifies the parent ----------

  def test_writable_block_writes_to_parent
    ca = CArray.int32(4, 5).seq
    bl = ca[1..2, 1..3]
    # Write -777 at block index [0,0] which is parent [1,1] = byte offset (1*5+1)*4 = 24
    flag = MVBorrower::STRIDES | MVBorrower::WRITABLE
    v = MVBorrower.inspect_view(bl, flag)
    assert_equal(false, v[:readonly])
    # The block view's data pointer is at parent->ptr + 24 bytes.  Writing at
    # offset 0 of the view is equivalent to parent[1,1].
    assert_true(MVBorrower.write_int32(bl, 0, -777))
    assert_equal(-777, ca[1, 1])
    # Block index [1,2] corresponds to parent[2,3] = byte offset (2*5+3)*4 = 52
    # within the view: row 1 * stride0 + col 2 * stride1 = 20 + 8 = 28
    assert_true(MVBorrower.write_int32(bl, 28, -888))
    assert_equal(-888, ca[2, 3])
  end

  # ---------- WRITABLE flag rejection on frozen / read-only arrays ----------

  def test_writable_rejects_frozen_array
    ca = CArray.int32(3, 4).seq
    ca.freeze
    flag = MVBorrower::STRIDES | MVBorrower::WRITABLE
    v = MVBorrower.inspect_view(ca, flag)
    assert_nil(v, "WRITABLE request should be rejected on a frozen CArray")
  end

  def test_writable_rejects_frozen_without_readonly_flag
    # Defense-in-depth: freeze via Kernel#freeze path that doesn't go through
    # rb_ca_freeze still sets OBJ_FROZEN on the Ruby object.  The producer
    # must reject WRITABLE in that case too.
    ca = CArray.int32(3).seq
    Object.instance_method(:freeze).bind_call(ca)
    flag = MVBorrower::STRIDES | MVBorrower::WRITABLE
    v = MVBorrower.inspect_view(ca, flag)
    assert_nil(v, "WRITABLE must be rejected when OBJ_FROZEN is set even if " \
                  "CA_FLAG_READ_ONLY wasn't")
  end

  def test_non_writable_still_works_on_frozen
    ca = CArray.int32(3, 4).seq
    ca.freeze
    v = MVBorrower.inspect_view(ca, MVBorrower::STRIDES)
    assert_not_nil(v, "frozen array should still be exportable as read-only")
    assert_equal(true, v[:readonly])
  end

  # ---------- SIMPLE flag rejection ----------

  def test_simple_flag_rejects_strided
    # Earlier the producer used to fall back to ATTACH (materialise a
    # snapshot) when a SIMPLE-only consumer asked for a strided view.
    # That had wrong MV semantics (deferred sync on release).  Now we
    # reject; consumers that need a contig snapshot use
    # CArray.from_memory_view(arr) or arr.to_ca.
    ca = CArray.int32(10).seq
    bl = ca[[0, 5, 2]]   # strided
    assert_nil(MVBorrower.inspect_view(bl, MVBorrower::SIMPLE))
  end

  def test_strides_flag_accepts_strided
    ca = CArray.int32(10).seq
    bl = ca[[0, 5, 2]]
    v = MVBorrower.inspect_view(bl, STRIDES)
    assert_not_nil(v)
  end

  def test_simple_flag_accepts_contiguous_block
    ca = CArray.int32(4, 5).seq
    bl = ca[1..2, 0..4]   # contiguous in memory: full rows
    v = MVBorrower.inspect_view(bl, MVBorrower::SIMPLE)
    assert_not_nil(v, "Contiguous block should accept SIMPLE")
    assert_true(v[:row_major])
  end

  # ---------- Phase 3: stride=0 repeat ----------

  def test_repeat_stride_zero
    ca = CArray.int32(3).seq          # [0, 1, 2]
    rp = ca[:%, 4]                    # shape [3,4]; repeat over dim 1
    assert_equal(CA_OBJ_REPEAT, rp.obj_type)
    v = MVBorrower.inspect_view(rp, STRIDES)
    assert_not_nil(v)
    assert_equal([3, 4], v[:shape])
    # data dim is dim 0 (count[0]==0, parent stride = 4); repeat dim is dim 1 (stride = 0)
    assert_equal([4, 0], v[:strides])
    # Verify a few accesses
    [[0, 0, 0], [0, 3, 0], [1, 0, 1], [2, 2, 2]].each do |i, j, expected|
      off = i * v[:strides][0] + j * v[:strides][1]
      assert_equal(expected, v[:data][off, 4].unpack1("l"))
    end
  end

  # ---------- non-CAStride virtuals: now rejected ----------
  # Previously these went through the ATTACH (materialise) path.  The
  # snapshot semantics were wrong for MV wrap (deferred sync; stale
  # reads; no explicit sync API).  Reject now; consumers wanting a
  # copy should use arr.to_ca.

  def test_select_rejected
    ca = CArray.int32(10).seq
    sel = ca[ca > 3]
    assert_nil(MVBorrower.inspect_view(sel, STRIDES))
  end

  def test_mapping_rejected
    ca = CArray.int32(10).seq
    idx = CArray.int32(4); idx[0]=3; idx[1]=1; idx[2]=5; idx[3]=7
    mp = ca[idx]
    assert_nil(MVBorrower.inspect_view(mp, STRIDES))
  end

  def test_shift_rejected
    ca = CArray.int32(5).seq
    sh = ca.shift(1)
    assert_nil(MVBorrower.inspect_view(sh, STRIDES))
  end

  def test_window_rejected
    ca = CArray.int32(5).seq
    w = ca.window(2..3)
    assert_nil(MVBorrower.inspect_view(w, STRIDES))
  end

  # ---------- compose-fold acceptance: non-contig intermediate ----------
  # Previously rejected because alias-chain required every parent to be
  # contig CAStride.  Compose-fold (2026-05-21) folds non-contig
  # CAStride intermediates as long as the leaf's strides decompose
  # cleanly into entity byte space.

  def test_sub_block_of_non_contig_block_accepted
    big = CArray.int32(20, 30, 40).seq
    sub = big[nil, 5, nil][2..9, 10..19]   # CABlock of non-contig CABlock
    v = MVBorrower.inspect_view(sub, STRIDES)
    assert_not_nil(v, "compose-fold should accept CABlock of non-contig CABlock")
    assert_equal([8, 10], v[:shape])
    # composed strides in big byte space:
    #   sub.dim 0 advances big.dim 0 → stride = 30*40*4 = 4800
    #   sub.dim 1 advances big.dim 2 → stride = 4
    assert_equal([4800, 4], v[:strides])
  end

  def test_block_of_transposed_accepted
    src = CArray.int32(3, 4).seq
    blk = src.transpose[1, nil]   # CABlock of CATranspose
    v = MVBorrower.inspect_view(blk, STRIDES)
    assert_not_nil(v, "compose-fold should accept CABlock of CATranspose")
    assert_equal([3], v[:shape])
    # blk[i] = transposed[1, i] = src[i, 1]; stride = src.strides[0] = 16
    assert_equal([16], v[:strides])
  end

  # ---------- attach symmetry on CAStride views ----------

  def test_attach_symmetry_block
    ca = CArray.int32(10, 10).seq
    bl = ca[2..5, 1..7]
    refute(bl.attached?)
    MVBorrower.inspect_view(bl, STRIDES)
    refute(bl.attached?, "CABlock must not be attached after release")
  end

  def test_attach_symmetry_repeated_get_release
    # Repeated zero-copy STRIDES wraps on the same CAStride view
    # should not leak attach count -- after N get+release pairs the
    # view stays in its original (unattached) state.
    ca = CArray.int32(10, 10).seq
    bl = ca[2..5, 1..7]
    10.times { MVBorrower.inspect_view(bl, STRIDES) }
    refute(bl.attached?, "no attach count leak after repeated get/release")
  end

  # ---------- SIMPLE on non-contig: rejected ----------
  #
  # The old code materialised a snapshot when a SIMPLE-only consumer
  # asked for a non-contig view (CABlock col slice, CAFarray ndim>=2,
  # CATranspose non-identity, CARepeat).  That deferred sync to the
  # consumer's release and clobbered concurrent writes on snapshot
  # scatter-back.  Now we reject with a helpful TypeError; consumers
  # wanting a contig copy should use CArray.from_memory_view(arr).

  SIMPLE = MVBorrower::SIMPLE

  def test_simple_on_non_contig_block_rejected
    ca = CArray.int32(4, 5).seq
    dest = ca[nil, 2]
    assert_nil(MVBorrower.inspect_view(dest, SIMPLE))
  end

  def test_simple_on_farray_2d_rejected
    ca = CArray.int32(2, 3).seq
    fa = ca.farray
    assert_nil(MVBorrower.inspect_view(fa, SIMPLE))
  end

  def test_simple_on_transpose_non_identity_rejected
    ca = CArray.int32(2, 3).seq
    tr = ca.transpose
    assert_nil(MVBorrower.inspect_view(tr, SIMPLE))
  end

  def test_simple_on_repeat_rejected
    ca = CArray.int32(3).seq
    rp = ca[:%, 4]
    assert_nil(MVBorrower.inspect_view(rp, SIMPLE))
  end

  def test_contiguous_block_still_zero_copy_under_simple
    # ca[1..2, true] is a contiguous CABlock; SIMPLE should keep
    # zero-copy strided path (not fall back to materialise).
    ca = CArray.int32(4, 5).seq
    bl = ca[1..2, nil]
    v = MVBorrower.inspect_view(bl, SIMPLE)
    assert_not_nil(v)
    assert_equal([2, 5], v[:shape])
    assert_equal([20, 4], v[:strides])   # zero-copy strides over parent
    assert_true(v[:row_major])
  end

  # ---------- attach! scope: nested wraps don't redundant-sync ----------
  #
  # The performance-critical pattern:
  #
  #   ca = big[nil, k, nil, nil]   # strided CABlock
  #   ca.attach! do
  #     N.times do |i|
  #       nc_get_vara(..., ca[i, nil, nil])   # inner zero-copy wraps
  #     end
  #   end
  #
  # produces 1 materialise + N zero-copy writes + 1 sync.  Inner
  # wrap releases must NOT sync (attach count > 1 means an outer
  # scope owns the sync).

  # Compose-fold (2026-05-21) lets MV wrap accept CAStride chains
  # whose intermediates are non-contig CAStride: the inner wrap
  # composes strides through the non-contig parent into entity byte
  # space, and reads/writes go directly into the entity's storage.
  # SIMPLE rejects when the leaf's composed strides are non-contig
  # in entity space; STRIDES accepts.
  def test_attach_bang_inner_wrap_accepts_with_strides_flag
    big = CArray.float64(8, 5, 3, 4).seq
    ca = big[nil, 2, nil, nil]    # strided (col slice), non-contig
    ca.attach! do
      inner = ca[0..1, nil, nil]   # 2 rows of ca; spans dim 0 stride 480
                                   # → non-contig in entity space
      # SIMPLE rejects: inner's composed strides are non-contig
      assert_nil(MVBorrower.inspect_view(inner,
                                         SIMPLE | MVBorrower::WRITABLE))
      # STRIDES accepts: zero-copy strided view directly into entity
      v = MVBorrower.inspect_view(inner, STRIDES | MVBorrower::WRITABLE)
      assert_not_nil(v)
      assert_equal([2, 3, 4], v[:shape])
      # Strides reflect entity byte layout: dim 0 stride = 480 (big's
      # dim 0 stride, inherited through ca's non-contig parent dim);
      # dims 1,2 stay at 32 and 8.
      assert_equal([480, 32, 8], v[:strides])
    end
  end

  # ---------- mask policy: .value path ----------

  def test_masked_value_view_data
    ca = CArray.int32(5).seq
    ca.mask = [0, 1, 0, 1, 0]
    v = MVBorrower.inspect_view(ca.value, STRIDES)
    assert_not_nil(v)
    # masked positions contain whatever the underlying memory holds; we only
    # assert the unmasked positions match seq().
    bytes_per = 4
    actual = (0...5).map { |i| v[:data][i * bytes_per, bytes_per].unpack1("l") }
    assert_equal(0, actual[0])
    assert_equal(2, actual[2])
    assert_equal(4, actual[4])
  end
end
