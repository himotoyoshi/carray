# frozen_string_literal: true
#
# spec_ai/test_cheap_attach_lifetime.rb
#
# Cheap Attach phase の L2 alias buffer lifetime safety regression pin。
# `devel/AUDIT_CHEAP_ATTACH_PER_VIEW.md` §5.1 で identify された 12 危険
# chain pattern に対する attach → use → detach lifecycle pin。
#
# Status: **Skeleton (W.0.5 deliverable)** — 各テストは現状 SKIP、W.1-W.8
# で実装が landed されるごとに pending 解除。
#
# 重要 invariant (= keep-attached cascade、AUDIT §6.4 (iii)):
#   1. L2 alias chain で outer view が attach されたら、内側 transform
#      view (= compose-fold root) も自動 keep-attached
#   2. outer view detach で root の attach count が dec、他に alias 子が
#      なければ root も detach
#   3. user が root を直接 detach しようとしても、alias 子が alive な間は
#      root.ptr は維持される (= ca_detach は cascade で skip / refcount
#      による free 抑止)
#   4. double-free なし、leak なし、use-after-free なし
#
# 検証手段:
#   - outer.attach! { ... } 中に root の `attached?` 状態を観察
#   - outer.attach! { root.detach! } で root の ptr が cleanly handle される
#   - GC stress (GC.compact / Thread.pass) で alias chain が破損しないこと
#   - outer.dump_binary / outer.to_ca 等の whole-view 経路で正しい値が出る

require "test/unit"
require_relative "../../lib/carray"

class TestCheapAttachLifetime < Test::Unit::TestCase

  # --- §5.1 危険 chain table の 12 pattern -----------------------------

  # Pattern #1: CABlock(CAFake(entity))
  def test_cablock_over_cafake_over_entity_lifetime
    omit "W.1 cheap attach landed 前は skip (lifetime mechanism 未実装)"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)              # CAFake(entity)、L3 owned scratch
    sliced = casted[10..90, 10..90]        # CABlock(CAFake(entity))、L2 alias

    sliced.attach! do |view|
      assert view.attached?, "outer view should be attached"
      assert_kind_of CArray, view
      # keep-attached cascade: CAFake も auto-attached されているはず
      assert casted.attached?,
        "L2 alias should keep CAFake (root) attached via cascade"
      # 値の正当性確認 (= alias 経路で正しい cast 結果が見える)
      assert_equal 30, view[0, 0]  # int32(src[10, 10]) = 30 * something
    end
    # outer detach 後、root も detach (= 他に alias 子なし)
    assert !casted.attached?,
      "CAFake should be detached after last L2 alias child detaches"
  end

  # Pattern #2: CARefer(CAFake(entity))
  def test_carefer_over_cafake_over_entity_lifetime
    omit "W.1 cheap attach landed 前は skip"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)
    reshaped = casted.reshape(50, 200)     # CARefer(CAFake(entity))
    reshaped.attach! do |view|
      assert casted.attached?, "cascade"
    end
    assert !casted.attached?
  end

  # Pattern #3: CATranspose(CAFake(entity))
  def test_catranspose_over_cafake_over_entity_lifetime
    omit "W.1 cheap attach landed 前は skip"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)
    transposed = casted.transpose          # CATranspose(CAFake(entity))
    transposed.attach! do |view|
      assert casted.attached?, "cascade"
    end
    assert !casted.attached?
  end

  # Pattern #4: CARepeat(CAFake(entity)) — broadcast
  def test_carepeat_over_cafake_over_entity_lifetime
    omit "W.1 cheap attach landed 前は skip"
    src = CArray.int16(100).seq
    casted = src.fake(:int32)
    repeated = casted.repeat(50, :%)       # CARepeat(CAFake(entity))
    repeated.attach! do |view|
      assert casted.attached?, "cascade"
    end
    assert !casted.attached?
  end

  # Pattern #5: CABlock(CAByteSwap(entity))
  def test_cablock_over_cabyteswap_over_entity_lifetime
    omit "W.3 + W.1 cheap attach landed 前は skip"
    src = CArray.int32(100, 100).seq
    swapped = src.swap_bytes               # CAByteSwap(entity)、L3 owned scratch
    sliced = swapped[10..90, 10..90]
    sliced.attach! do |view|
      assert swapped.attached?, "cascade"
    end
    assert !swapped.attached?
  end

  # Pattern #6: CARefer(CAByteSwap(entity))
  def test_carefer_over_cabyteswap_over_entity_lifetime
    omit "W.3 + W.1 前は skip"
    src = CArray.int32(100, 100).seq
    swapped = src.swap_bytes
    reshaped = swapped.reshape(50, 200)
    reshaped.attach! do |view|
      assert swapped.attached?
    end
    assert !swapped.attached?
  end

  # Pattern #7: CATranspose(CAByteSwap(entity))
  def test_catranspose_over_cabyteswap_over_entity_lifetime
    omit "W.3 + W.1 前は skip"
    src = CArray.int32(100, 100).seq
    swapped = src.swap_bytes
    transposed = swapped.transpose
    transposed.attach! do |view|
      assert swapped.attached?
    end
    assert !swapped.attached?
  end

  # Pattern #8: CABlock(CABitfield(entity))
  def test_cablock_over_cabitfield_over_entity_lifetime
    omit "W.4 + W.1 前は skip"
    src = CArray.uint32(100).seq
    bf = src.bitfield(0..7)                # CABitfield(entity)、L3 owned scratch
    sliced = bf[10..90]
    sliced.attach! do |view|
      assert bf.attached?, "cascade"
    end
    assert !bf.attached?
  end

  # Pattern #9: CABlock(CABitarray(entity))
  def test_cablock_over_cabitarray_over_entity_lifetime
    omit "W.4 + W.1 前は skip"
    src = CArray.uint8(100).seq
    ba = src.bit_array                      # CABitarray(entity)、L4 owned scratch
    # CABitarray は要素数 8x になるので index 調整
    sliced = ba[10..90]
    sliced.attach! do |view|
      assert ba.attached?, "cascade"
    end
    assert !ba.attached?
  end

  # Pattern #10: CAField(CAFake(entity)) — struct field projection over cast
  def test_cafield_over_cafake_over_entity_lifetime
    omit "W.1 前は skip (CAField over transform は稀ケース、low priority)"
    # struct chain 構築は複雑、W.0.5 では skeleton のみ
  end

  # Pattern #11: CAWindow_interior(CAFake(entity)) — Phase 1.5 fold_stride
  def test_cawindow_interior_over_cafake_over_entity_lifetime
    omit "W.2 + W.3 + W.1 前は skip"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)
    # interior-only window (= 境界 OOB を touch しない)
    window = casted.window(10..90, 10..90, fill_value: 0)
    window.attach! do |view|
      # fold_stride で CAFake で break、L2 alias が CAFake scratch を指す
      assert casted.attached?, "cascade through fold_stride"
    end
    assert !casted.attached?
  end

  # Pattern #12: nested chain CABlock(CARefer(CAFake(entity)))
  def test_nested_cablock_carefer_cafake_lifetime
    omit "W.1 前は skip"
    src = CArray.int16(1000).seq
    casted = src.fake(:int32)
    reshaped = casted.reshape(10, 100)
    sliced = reshaped[2..8, 10..90]
    sliced.attach! do |view|
      # chain depth 2 の outer view が compose-fold で CAFake root に到達
      assert casted.attached?, "cascade through multi-layer chain"
    end
    assert !casted.attached?
  end

  # --- ユーザによる root 直接 detach の防御 ----------------------------

  def test_root_detach_protected_by_cascade
    omit "W.8 lifetime safety machinery 前は skip"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)
    sliced = casted[10..90, 10..90]
    sliced.attach! do |view|
      # alias 子が alive な間に user が root を detach しようとする
      # 期待挙動: cascade が free 抑止 / refcount で skip、ptr 維持
      casted.detach!  # ← 通常なら scratch が free されるが、cascade で抑止
      # view->ptr (= casted->ptr の alias) が依然 valid
      assert_nothing_raised do
        x = view[0, 0]
        assert_kind_of Integer, x
      end
    end
  end

  # --- GC stress under L2 alias ---------------------------------------

  def test_gc_compact_does_not_break_l2_alias
    omit "W.1 前は skip"
    src = CArray.int16(100, 100).seq
    casted = src.fake(:int32)
    sliced = casted[10..90, 10..90]
    sliced.attach! do |view|
      GC.compact if GC.respond_to?(:compact)
      GC.start
      # alias chain が GC で破損しないこと
      assert_equal sliced[0, 0], view[0, 0]
    end
  end

  # --- double-free / leak detection -----------------------------------

  def test_no_double_free_on_normal_lifecycle
    omit "W.8 前は skip"
    # ObjectSpace.count_objects 等で leak 検出は session 横断が必要
    # ここでは crash しないことだけ pin
    100.times do
      src = CArray.int16(100, 100).seq
      casted = src.fake(:int32)
      sliced = casted[10..90, 10..90]
      sliced.attach! { |v| v[0, 0] }
    end
    # GC を強制実行、crash しなければ OK
    GC.start
  end

  # --- value-level correctness (= alias 経路の cast 透過性) ------------

  def test_value_correctness_through_l2_alias
    omit "W.1 + W.3 前は skip"
    src = CArray.int16(10, 10).seq          # 0, 1, 2, ..., 99
    casted = src.fake(:int32)               # int32 view、値は同じ
    sliced = casted[2..7, 3..8]             # CABlock(CAFake(entity))

    # alias 経路と materialise 経路で同値
    via_alias = sliced.to_a                 # L2 alias 経由
    via_materialise = sliced.dup.to_a       # CABlock 自身を materialise
    assert_equal via_materialise, via_alias,
      "L2 alias should produce same values as direct materialise"
  end

  # --- streaming reduce (= W.5 CAReduce) lifetime --------------------

  def test_streaming_reduce_does_not_create_scratch
    omit "W.5 streaming reduce 前は skip"
    src = CArray.float64(1000, 1000).seq
    reduced = src.sum(axis: 0)
    # streaming reduce path では whole-source scratch を作らない
    # (= parent slab 単位 stream-through + accumulate)
    # 検証: peak memory が src.bytes * src.elements * 2 にならないこと
    # → 詳細 spec は W.5 で詰める
    assert_equal src.sum_along_axis_0, reduced
  end
end
