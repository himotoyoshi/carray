# M5 (PROPOSAL_RESHAPE_STRIDE_REWRITE): pin existing CARefer behavior
# across all 6 roles before the reshape stride rewrite refactor.
#
# Roles audited:
#   1. pure reshape  via #reshape         (rb_ca_reshape)        — touched by refactor (class may change to CAStride)
#   2. pure flatten  via #flatten         (rb_ca_flatten)        — touched by refactor (class may change to CAStride)
#   3. byte/type reinterpret via #refer   (rb_ca_refer)          — NOT touched
#   4. mask propagation                                          — NOT touched
#   5. internal use from other view ctors                        — NOT touched
#   6. range-index 1-D refer              (rb_ca_refer_new_flatten) — NOT touched
#
# For roles 1-2 we assert content equivalence only (no class check, since
# the refactor will produce CAStride for representable cases).
# For roles 3-6 we assert content AND that class remains CARefer.

require "test/unit"
require "carray"

class TestCAReferRolesIntact < Test::Unit::TestCase

  # ===== Role 1: pure reshape =====

  def test_role1_reshape_on_entity
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(6, 4)
    assert_equal [6, 4], r.dim
    assert_equal a.to_a.flatten, r.to_ca.to_a.flatten
  end

  def test_role1_reshape_on_block_full_contig
    a = CArray.float64(4, 6).seq
    sub = a[1..2, nil]   # contig sub
    r = sub.reshape(2, 6)
    assert_equal [2, 6], r.dim
    assert_equal sub.to_ca.to_a.flatten, r.to_ca.to_a.flatten
  end

  def test_role1_reshape_on_block_non_contig
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]   # non-contig in axis 1
    r = sub.reshape(2, 8)
    assert_equal [2, 8], r.dim
    assert_equal sub.to_ca.to_a.flatten, r.to_ca.to_a.flatten
  end

  def test_role1_reshape_writes_propagate_to_entity
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(6, 4)
    r[0, 0] = -1.0
    assert_equal(-1.0, a[0, 0, 0])
  end

  # ===== Role 2: pure flatten =====

  def test_role2_flatten_on_entity
    a = CArray.float64(2, 3, 4).seq
    f = a.flatten
    assert_equal [24], f.dim
    assert_equal (0..23).map(&:to_f), f.to_a
  end

  def test_role2_flatten_on_block
    a = CArray.float64(2, 3, 4).seq
    f = a[nil, 1..2, nil].flatten
    assert_equal [16], f.dim
    assert_equal a[nil, 1..2, nil].to_ca.to_a.flatten, f.to_a
  end

  def test_role2_flatten_writes_propagate
    a = CArray.float64(3, 3).seq
    f = a.flatten
    f[4] = -99.0
    assert_equal(-99.0, a[1, 1])
  end

  # ===== Role 3: byte/type reinterpret via #refer =====

  def test_role3_refer_same_bytes_type_change
    # int32 reinterpreted as another 4-byte type via different data_type;
    # simplest is same type with shape change (= bytes == parent_bytes).
    a = CArray.int32(4, 5).seq
    r = a.refer(:int32, [5, 4])
    assert_equal "CARefer", r.class.name
    assert_equal [5, 4], r.dim
    assert_equal a.to_a.flatten, r.to_a.flatten
  end

  def test_role3_refer_divided_smaller_bytes
    # bytes < parent_bytes: each int32 splits into 4 int8.
    a = CArray.int32(2, 3).seq
    r = a.refer(:int8, [2, 12])   # 4-byte int32 -> 4 int8 per element
    assert_equal "CARefer", r.class.name
    assert_equal [2, 12], r.dim
    # value at position [i, 4*j+0] should be low byte of a[i,j] (little-endian assumed)
    # Just check round-trip via byte length
    assert_equal a.elements * 4, r.elements
  end

  def test_role3_refer_spanned_larger_bytes
    # bytes > parent_bytes: 4 int8 fold into 1 int32.
    a = CArray.int8(2, 12).seq
    r = a.refer(:int32, [2, 3])
    assert_equal "CARefer", r.class.name
    assert_equal [2, 3], r.dim
    assert_equal 6, r.elements
  end

  def test_role3_refer_with_offset
    a = CArray.int32(10).seq
    r = a.refer(:int32, [5], offset: 5)
    assert_equal "CARefer", r.class.name
    assert_equal (5..9).to_a, r.to_a
  end

  # Role 3g: ca_refer_create_mask spanned mode (bytes > parent_bytes).
  # ratio = bytes/parent_bytes parent mask bits OR-fold into one.
  def test_role3_refer_spanned_mode_mask
    a = CArray.int8(12).seq
    a.mask = 0
    a[5] = UNDEF   # mask bit 5 set
    r = a.refer(:int32, [3])   # 4 int8 fold into 1 int32; bit 5 is in element 1
    assert_equal "CARefer", r.class.name
    assert_true r.has_mask?
    # Bit 5 of source falls in [4..7] which folds to int32 index 1.
    # OR-fold means: any bit set in [4..7] → output bit at index 1 is set.
    assert_equal true, r.is_masked[1], "spanned mask OR-fold must mark index 1"
    assert_equal false, r.is_masked[0]
    assert_equal false, r.is_masked[2]
  end

  # ===== Role 4: mask propagation via #reshape on masked array =====

  def test_role4_reshape_preserves_mask_simple
    a = CArray.float64(2, 3, 4).seq
    a.mask = 0
    a[0, 1, 2] = UNDEF
    r = a.reshape(6, 4)
    # mask should round-trip through reshape view
    assert_equal a.has_mask?, r.has_mask?
    assert_true r.is_masked.flatten.to_a.any?
    # the masked position should still be UNDEF when read via reshape
    mat = r.to_ca
    assert_equal UNDEF, mat[1, 2]  # original [0,1,2] flattened to [1,2] in (6,4)
  end

  def test_role4_flatten_preserves_mask
    a = CArray.float64(3, 4).seq
    a.mask = 0
    a[1, 2] = UNDEF
    f = a.flatten
    assert_equal a.has_mask?, f.has_mask?
    assert_equal UNDEF, f.to_ca[6]   # [1, 2] flattens to index 6
  end

  def test_role4_refer_simple_mode_mask
    a = CArray.int32(2, 6).seq
    a.mask = 0
    a[0, 3] = UNDEF
    r = a.refer(:int32, [3, 4])
    assert_equal "CARefer", r.class.name
    assert_true r.has_mask?
    # index [0,3] in original = flat index 3 = [0,3] in (3,4)
    assert_equal UNDEF, r.to_ca[0, 3]
  end

  def test_role4_refer_divided_mode_mask
    # divided mode: 1 parent mask bit broadcasts to ratio sub-positions
    a = CArray.int32(2, 3).seq
    a.mask = 0
    a[0, 1] = UNDEF
    r = a.refer(:int8, [2, 12])
    assert_equal "CARefer", r.class.name
    assert_true r.has_mask?
    # the 4 bytes of a[0,1] should all be masked: positions [0, 4..7]
    mat = r.to_ca
    (4..7).each do |j|
      assert_equal UNDEF, mat[0, j], "byte at [0,#{j}] should be UNDEF"
    end
    # neighbouring bytes should not be masked
    assert_not_equal UNDEF, mat[0, 0]
    assert_not_equal UNDEF, mat[0, 8]
  end

  # Role 4a: CABitfield uses ca_refer_new (ca_obj_bitfield.c:410) to wrap
  # the parent's mask during view construction, then ca_refer's own
  # gather/sync moves the mask bits when the view materialises.  Both
  # the wrap (construction) and the read-through (is_masked) must work.
  def test_role4_bitfield_mask_propagation
    a = CArray.uint32(4).seq
    a.mask = 0
    a[2] = UNDEF
    bf = a.bitfield(0..3)   # low 4 bits as CABitfield; constructs CARefer mask
    assert_equal "CABitfield", bf.class.name
    assert_true bf.has_mask?, "ca_refer_new at ca_obj_bitfield.c:410 must produce a mask"
    assert_equal [false, false, true, false], bf.is_masked.to_a
    # Force GC to flush the (formerly bogus) mask TypedData dfree path.
    GC.start
    assert_equal [false, false, true, false], bf.mask.to_a
  end

  # Role 4b: CAFake uses ca_refer_new (ca_obj_fake.c:307) to wrap parent's
  # mask through type-cast.  Type widens (int32 → float64), but the mask
  # is per-element so each masked source element stays masked in the view.
  def test_role4_fake_mask_propagation
    a = CArray.int32(4).seq
    a.mask = 0
    a[1] = UNDEF
    f = a.fake(:float64)   # type-cast view; constructs CARefer mask
    assert_equal "CAFake", f.class.name
    assert_true f.has_mask?, "ca_refer_new at ca_obj_fake.c:307 must produce a mask"
    assert_equal [false, true, false, false], f.is_masked.to_a
    GC.start
    assert_equal [false, true, false, false], f.mask.to_a
  end

  # ===== Role 5: internal CARefer use from other view classes =====

  # Role 4c: CAByteSwap uses ca_refer_new (ca_obj_byte_swap.c:363) to wrap
  # the parent's mask.  Masked source must propagate through swap_bytes view.
  def test_role4_byteswap_mask_propagation
    a = CArray.int32(4).seq
    a.mask = 0
    a[2] = UNDEF
    sw = a.swap_bytes
    # swap_bytes is a CAByteSwap view; to_ca materialises
    mat = sw.to_ca
    # masked position should still be UNDEF after byte-swap view + materialise
    assert_equal UNDEF, mat[2]
  end

  # Role 5e: CAField uses rb_ca_refer_new (ca_obj_field.c:168) for internal
  # type-and-shape adjustment when constructing the struct member view.
  def test_role5_field_path
    s_class = CArray.struct(pack: 1) {
      int32 :a
      float64 :b
    }
    arr = CARecord.new(s_class, 5)
    arr["a"][0] = 42
    arr["b"][0] = 3.14
    assert_equal 42, arr["a"][0]
    assert_in_delta 3.14, arr["b"][0], 1e-12
  end

  # Role 5a: CAGrid uses rb_ca_refer_new (ca_obj_grid.c:495) to reshape
  # the receiver before applying the grid spec.  Exercise with a masked
  # parent + grid construction.
  def test_role5_grid_path
    a = CArray.float64(4, 5).seq
    a.mask = 0
    a[0, 1] = UNDEF
    g = a.grid(CA_INT32([0, 2]), nil)
    assert_equal "CAGrid", g.class.name
    assert_true g.has_mask?
    mat = g.to_ca
    # g[0, *] = a[0, *]; original UNDEF at a[0, 1] propagates to g[0, 1]
    assert_equal UNDEF, mat[0, 1]
    assert_not_equal UNDEF, mat[0, 0]
    # g[1, *] = a[2, *]; no UNDEF
    assert_not_equal UNDEF, mat[1, 1]
  end

  # Role 5b: CAUnboundRepeat uses rb_ca_refer_new (ca_obj_unbound_repeat.c:218)
  # internally during construction.  Pin the construction site (without
  # mask, since UnboundRepeat + mask is a separate latent issue).
  def test_role5_unbound_repeat_path
    a = CArray.float64(3).seq
    ur = a.unbound_repeat(:*, nil)
    assert_equal "CAUnboundRepeat", ur.class.name
    assert_equal [1, 3], ur.dim
  end

  # Role 5c: #value uses rb_ca_refer_new (carray_mask.c:654) to construct
  # the value-array view that strips the mask.
  def test_role5_value_array_path
    a = CArray.int32(3).seq
    a.mask = [1, 0, 0]
    v = a.value
    assert_equal "CARefer", v.class.name
    assert_false v.has_mask?, "ca.value must strip the mask"
    # Reads ignore the mask: underlying bytes (= 0 for masked cell since
    # seq filled before mask) visible directly.
    assert_equal 0, v[0]
    assert_equal 1, v[1]
    assert_equal 2, v[2]
  end

  # Role 5d: CARepeat construction with shape adjustment via rb_ca_refer_new
  # (ca_obj_repeat.c:161/187/225).  broadcast_to is the public path that
  # exercises rb_ca_repeat / the inner refer-new shape adjustment.
  def test_role5_repeat_path
    a = CArray.int32(1, 4).tap { |__a| __a[] = [10, 20, 30, 40] }
    a.mask = [[0, 1, 0, 0]]
    r = a.broadcast_to(3, 4)
    assert_equal "CARepeat", r.class.name
    assert_true r.has_mask?
    # The masked position [0,1] should propagate across all repeats
    mat = r.to_ca
    (0..2).each do |i|
      assert_equal UNDEF, mat[i, 1], "row #{i} col 1 must be UNDEF (broadcast)"
      assert_not_equal UNDEF, mat[i, 0]
    end
  end

  # ===== Role 6: range-index 1-D refer (rb_ca_refer_new_flatten) =====

  def test_role6_flatten_via_address_indexing
    # ca[i] on a multi-dim array triggers CA_REG_FLATTEN path which uses
    # rb_ca_refer_new_flatten internally.
    a = CArray.float64(3, 4).seq
    assert_equal 5.0, a[5]   # flat index access
    a[5] = -1.0
    assert_equal(-1.0, a[1, 1])
  end

  # ===== Combined: chained reshape =====

  def test_combined_chained_reshape
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(6, 4).reshape(3, 8)
    assert_equal [3, 8], r.dim
    assert_equal a.to_a.flatten, r.to_ca.to_a.flatten
  end

  def test_combined_reshape_then_block
    a = CArray.float64(2, 3, 4).seq
    sub = a.reshape(6, 4)[1..3, nil]
    assert_equal [3, 4], sub.dim
    expected = a.to_a.flatten[4...16]
    assert_equal expected, sub.to_ca.to_a.flatten
  end
end
