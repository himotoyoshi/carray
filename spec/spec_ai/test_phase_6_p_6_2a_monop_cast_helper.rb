require "test/unit"
require "carray"

# Phase 6 P.6.2.a foundational helper test
#
# Pins behavior of the (currently C-internal) helper
# `ca_monop_view_is_single_cast` indirectly: verifies that the cast op_id
# space CAMonOp::CAST_BASE is exposed and that single-cast CAMonOp views
# can be constructed using the existing arena materialise path.  Direct
# C-level discrimination test will be added in P.6.2.b when the helper is
# wired into ca_kernel_iterator.c.
#
# These tests pin baseline behavior so any change to the cast op_id space
# (Q3 / Q6 / Q11 round 2 locks) is caught.

class TestPhase6P62aMonopCastHelper < Test::Unit::TestCase

  def test_cast_base_constant_exposed
    # Q3 lock: cast ops live in CA_MONOP_CAST_BASE + data_type range.
    assert_equal 100, CAMonOp::CAST_BASE
  end

  def test_chain_materialise_cast_at_leaf_byte_parity
    # Indirect P.6.2.a smoke: existing chain materialise with cast-before
    # (= widening monfunc on integer parent) inserts CAMonOp(cast_f64)
    # node at innermost position, which is structurally equivalent to
    # `ca_monop_view_is_single_cast` returning true if the cast were
    # exposed as standalone.  Confirms the cast kernel path itself is
    # green (= P.6.2 prereq).
    a = CArray.int32(8).seq!(1)
    lazy_result  = a.lazy.sqrt.to_a
    eager_result = a.sqrt.to_a
    a.dim[0].times do |i|
      assert_in_delta eager_result[i], lazy_result[i], 1e-12,
                      "lazy chain cast+sqrt mismatch at i=#{i}"
    end
  end

  def test_p62b4_as_int32_returns_camonop
    # P.6.2.b.4 landed: Ruby surface `as_int32` 等 numeric short-hand を
    # CAMonOp(cast_<dt>) に migration 完了 (Q11 (E) fake narrow).
    a = CArray.float64(4).seq!(1.5)
    v = a.as_int32
    assert_kind_of CAMonOp, v
    assert_equal CA_INT32, v.data_type
  end

  def test_p62b4_as_type_numeric_routes_to_camonop
    a = CArray.float64(4).seq!(1.5)
    %i[as_int8 as_int16 as_int32 as_int64 as_float32].each do |method|
      v = a.send(method)
      assert_kind_of CAMonOp, v, "#{method} should return CAMonOp"
    end
  end

  def test_p62b4_as_type_fixlen_still_returns_cafake
    # Q11 (E) narrow CAFake retain: CA_FIXLEN cast は CAFake のまま.
    b = CArray.fixlen(3, bytes: 4)
    b[] = ["abc ", "def ", "ghi "]
    v = b.as_type(:fixlen, bytes: 4)
    assert_kind_of CAFake, v
  end

  def test_p62b4_helper_recognises_migrated_view
    # P.6.2.a helper ca_monop_view_is_single_cast: 本 view は single-cast
    # = recognised target.  実検証は内部 C function なので、
    # 間接的に view が CAMonOp かつ writable であることで確認.
    a = CArray.float64(4).seq!(1.5)
    v = a.as_int32
    assert_kind_of CAMonOp, v
    assert_equal false, v.read_only?
  end

  # ----- P.6.2.d F.6.2 fast path wire-up -----

  def test_p62d_per_fiber_fused_path_works_for_cast_view
    # P.6.2.d wire-up: kernel_iterator F.6.2 discrimination は
    # ca_monop_view_is_single_cast 経由で migrated CAMonOp(cast) view を
    # 認識する.  動作確認 = `a.as_int32.sum(axis: 1)` 等の reduction が
    # 旧 CAFake 経路と同 result.
    n = 100
    a = CArray.float64(n, n).seq!(0.0)
    v = a.as_int32       # CAMonOp(cast)
    sum_axis = v.sum(axis: 1)
    assert_equal [n], sum_axis.dim
    # 各 row の sum は予測可能: row i は i*n .. i*n+n-1 の int32 cast sum.
    # (= 各 cell は float64 を int32 cast、行 i の cell は i*n+j as float = i*n+j (整数))
    expected_row_0 = (0...n).sum
    assert_equal expected_row_0, sum_axis[0]
  end

  def test_p62d_chain_camonop_not_per_fiber_fused
    # chain CAMonOp (= depth >= 2) は F.6.2 fast path から除外、
    # chain materialise path を維持.  動作確認 = `a.lazy.sqrt.as_int32`
    # の reduction が正しく動く.
    a = CArray.float64(8).seq!(1.0)
    chained = a.lazy.sqrt.as_int32   # depth 2 chain
    # The result should be sqrt(i+1) cast to int32 for i in 0..7
    result = chained.to_a
    expected = (1..8).map { |x| Math.sqrt(x).to_i }
    assert_equal expected, result
  end

  # ----- P.6.2.b.1 writable cast path -----

  def test_p62b_cast_view_is_writable
    # Q14 (i') de facto continuation: cast op_id 経路で CA_FLAG_READ_ONLY
    # 未 set (= 既存 CAFake と同じ writable semantic).
    a = CArray.float64(8).seq!(1.5)
    v = CAMonOp.__build__(a, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    assert_equal false, v.read_only?, "cast view should be writable"
  end

  def test_p62b_noncast_view_is_readonly
    # 確認: monop / monfunc 等の non-cast op は従来通り read-only 保持.
    a = CArray.float64(4).seq!(1.0)
    v = CAMonOp.__build__(a, 3)  # CA_MONOP_NEG = 3
    assert_equal true, v.read_only?, "non-cast monop should remain read-only"
  end

  def test_p62b_cast_view_putdone_reverses_cast
    # Q15 lock + Q14 (i'): view[idx] = v で reverse-cast → parent store.
    a = CArray.float64(4).seq!(10.5)   # [10.5, 11.5, 12.5, 13.5]
    v = CAMonOp.__build__(a, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    v[0] = 99
    assert_equal 99,    v[0]              # view 経由で 99 を読める
    assert_equal 99.0,  a[0]              # parent は reverse-cast 後 99.0
    assert_equal 11.5,  a[1]              # 他 cell 不変
    assert_equal 13.5,  a[3]
  end

  def test_p62b_read_path_byte_parity_with_legacy_as_int32
    # 後方互換: cast 経路 read は legacy `.as_int32` と byte parity.
    a = CArray.float64(16).seq!(0.1)
    v_new    = CAMonOp.__build__(a, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    v_legacy = a.as_int32
    assert_equal v_legacy.to_a, v_new.to_a
  end

  # ----- P.6.2.b.2 fill_data + xfer_stride PUT + xfer_addrs PUT -----

  def test_p62b_fill_data_reverse_casts_to_parent
    # v.fill(N) → ca_ptr2ptr(self, N, parent, scratch); ca_fill(parent).
    a = CArray.float64(6).seq!(0.5)
    v = CAMonOp.__build__(a, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    v.fill(42)
    assert_equal [42.0]*6, a.to_a              # parent fills with float64 42.0
    assert_equal [42]*6,   v.to_a              # view shows int32 42
  end

  def test_p62b_xfer_stride_put_reverse_casts_array_to_parent
    # x[range] = array → xfer_stride PUT (= ca_cast_block + ca_xfer_stride parent).
    c = CArray.float64(8).seq!(100.5)
    x = CAMonOp.__build__(c, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    src = CArray.int32(4) { |i| -i }
    x[2..5] = src
    assert_equal [100.5, 101.5, 0.0, -1.0, -2.0, -3.0, 106.5, 107.5], c.to_a
    assert_equal [100, 101, 0, -1, -2, -3, 106, 107],                   x.to_a
  end

  def test_p62b_whole_view_fill_via_indexer
    # v[] = N (= whole view fill, goes through fill_data).
    b = CArray.float64(8).seq!(10.5)
    w = CAMonOp.__build__(b, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    w[] = 5
    assert_equal [5.0]*8, b.to_a
    assert_equal [5]*8,   w.to_a
  end

  # ----- P.6.2.b.3 writable sync lifecycle (sub-view fill propagation fix) -----

  # A partial fill writes only the cells it addresses.  These two used to
  # expect the untouched .5 fractions to be gone -- 10.5 coming back 10.0 --
  # because filling part of a view attached the whole cast parent and synced
  # it all back, carrying every cell through float64 -> int32 -> float64 on
  # the way.  The fill now descends per cell, so cells outside the range are
  # not read and not rewritten.
  # See devel/PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md.

  def test_p62b3_subview_scalar_fill_propagates_to_parent
    # P.6.2.b.3 fix: `view[range] = scalar` で CABlock-on-CAMonOp(cast)
    # sub-view fill が parent に正しく propagate する (writable sync
    # lifecycle 強化 = ca_attach(parent) in allocate/attach +
    # ca_cast_block self→parent in sync + ca_detach(parent) in detach,
    # CAFake pattern 同型).
    b = CArray.float64(8).seq!(10.5)
    w = CAMonOp.__build__(b, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    w[1..4] = 7
    assert_equal [10.5, 7.0, 7.0, 7.0, 7.0, 15.5, 16.5, 17.5], b.to_a
    assert_equal [10, 7, 7, 7, 7, 15, 16, 17], w.to_a
  end

  def test_p62b3_subview_explicit_fill_propagates
    # 同 fix: `sl = view[range]; sl[] = val` でも sub-view fill が propagate.
    b = CArray.float64(8).seq!(10.5)
    w = CAMonOp.__build__(b, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    sl = w[1..4]
    sl[] = 9
    assert_equal [10.5, 9.0, 9.0, 9.0, 9.0, 15.5, 16.5, 17.5], b.to_a
    assert_equal [9, 9, 9, 9], sl.to_a
  end

  def test_p62b3_matches_cafake_lossy_roundtrip
    # writable cast の lossy round-trip semantic が legacy CAFake と完全
    # parity. as_int32 経由と CAMonOp(cast_int32) 経由で同 result.
    b1 = CArray.float64(6).seq!(0.5)
    b2 = CArray.float64(6).seq!(0.5)
    v1 = b1.as_int32                                   # legacy CAFake
    v2 = CAMonOp.__build__(b2, CAMonOp::CAST_BASE + CArray.data_type_code(CA_INT32))
    v1[2..4] = 100
    v2[2..4] = 100
    assert_equal b1.to_a, b2.to_a, "lossy round-trip must match CAFake"
  end
end
