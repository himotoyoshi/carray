# frozen_string_literal: true
#
# spec_ai/test_caobject_suspicious.rb
#
# CAObject の「怪しい場所」を狙い撃ちするテスト集。
#
# 焦点 (執筆中に判明した実装の実態を踏まえて pin):
#   1. :parent option (2026-05-26 に inverted-check bug を修正、振る舞いを pin)
#   2. CAObjectMask TypedData 配線 (X1 系 double-free pattern が残っていないか GC stress)
#   3. callback dispatch (fetch_addr / fetch_index 片方だけ定義した時の翻訳経路)
#   4. UNDEF 返却 -> mask 自動生成の GC 安全性
#   5. read_only / 書き込み禁止経路 (FrozenError 経路 + flag inheritance)
#   6. dup の foot-gun (ivar 共有: Ruby Object#dup の標準動作だが要注意)
#   7. bulk callback contract: copy_data は **必須** (fallback なし、未定義は NoMethodError)
#   8. fixlen の bytes 検証は **無い** (silent に bytes=0)
#
# 実行: ruby -Iext -Ilib spec_ai/test_caobject_suspicious.rb
#

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"

# ===========================================================================
# Fixture subclasses
# ===========================================================================

# 単一 parent 派生 (:parent option を使う典型)
class SquareView < CAObject
  def initialize(parent)
    @p = parent
    super(parent.data_type, parent.dim, parent: parent)
  end
  private
  def fetch_addr(addr); @p[addr] ** 2; end
  def copy_data(data); n = @p.elements; n.times { |i| data[i] = @p[i] ** 2 }; end
end

# fetch_index のみ定義 (fetch_addr は engine が翻訳して呼んでくれるはず)
class IndexOnlyArr < CAObject
  def initialize(dim)
    super(CA_INT32, dim, read_only: true)
  end
  private
  def fetch_index(idx); idx.inject(0) { |acc, i| acc * 100 + i }; end
  def copy_data(data)
    data.each_index { |*idx| data[*idx] = fetch_index(idx) }
  end
end

# fetch_addr のみ定義
class AddrOnlyArr < CAObject
  def initialize(dim)
    super(CA_INT32, dim, read_only: true)
  end
  private
  def fetch_addr(addr); addr * 3; end
  def copy_data(data); data.elements.times { |i| data[i] = i * 3 }; end
end

# UNDEF を返して mask を自動生成させる
class UndefAtOdd < CAObject
  def initialize(n)
    super(CA_INT32, [n])
  end
  private
  def fetch_addr(addr); addr.odd? ? UNDEF : addr * 10; end
  def copy_data(data)
    data.elements.times { |i| data[i] = i.odd? ? UNDEF : i * 10 }
  end
  # CAObject で mask を使うには create_mask を **override 必須** (no-op で可)。
  # default は "can't create mask for CAObject" で raise する。
  def create_mask
  end
end

# 書き込み可能 (write path 確認用)
class MutableObj < CAObject
  def initialize(n)
    @buf = Array.new(n, 0)
    super(CA_INT32, [n])
  end
  private
  def fetch_addr(addr); @buf[addr]; end
  def store_addr(addr, val); @buf[addr] = val; end
  def copy_data(data); @buf.each_with_index { |v, i| data[i] = v }; end
  def sync_data(data); data.elements.times { |i| @buf[i] = data[i] }; end
  def fill_data(value); @buf.fill(value); end
end

# 故意に copy_data を実装しない (fallback の有無を確認するため)
class NoBulkObj < CAObject
  def initialize(n)
    super(CA_INT32, [n], read_only: true)
  end
  private
  def fetch_addr(addr); addr; end
end

# ===========================================================================
# 1. :parent option (2026-05-26 fix の振る舞いを pin)
# ===========================================================================
class TestParentOption < Test::Unit::TestCase
  def test_accepts_carray_no_raise
    base = CArray.float64(3).seq
    sq = SquareView.new(base)
    assert_equal base.object_id, sq.parent.object_id
  end

  def test_rejects_non_carray
    assert_raise(RuntimeError) {
      Class.new(CAObject) {
        def initialize; super(CA_INT32, [3], parent: "not a carray"); end
        def fetch_addr(a); 0; end
        def copy_data(d); d[] = 0; end
      }.new
    }
  end

  def test_nil_parent_is_noop
    obj = Class.new(CAObject) {
      def initialize; super(CA_INT32, [3], parent: nil); end
      def fetch_addr(a); 0; end
      def copy_data(d); d[] = 0; end
    }.new
    assert_nil obj.parent
  end

  # :parent option の本来の存在意義: parent の flag を継承する
  def test_readonly_inherits_from_frozen_parent
    base = CArray.float64(3).seq
    base.freeze
    sq = SquareView.new(base)
    assert sq.read_only?,
      "frozen :parent should propagate read_only? via ca_is_readonly walking parent"
  end

  def test_not_readonly_when_parent_mutable
    base = CArray.float64(3).seq
    sq = SquareView.new(base)
    assert !sq.read_only?
  end

  # rb_ca_set_parent が frozen を伝播
  def test_frozen_propagates_from_parent
    base = CArray.float64(3).seq.freeze
    sq = SquareView.new(base)
    assert sq.frozen?, "frozen parent should freeze the CAObject too"
  end

  def test_parent_kept_alive_by_anchor
    sq = SquareView.new(CArray.float64(3).seq)
    GC.start
    GC.start
    assert_equal 4.0, sq[2]   # parent ([0,1,2]) ** 2 -> [0,1,4]
  end
end

# ===========================================================================
# 2. CAObjectMask / mask propagation
#
# 観察された事実 (= bug か設計判断か未確定、要調査):
#   - bulk path (copy_data 内で `data[i] = UNDEF`) は data の内部 CArray に
#     mask を作るが、それが to_ca 結果にも CAObject 本体 (self) にも
#     伝播しない。`result.has_mask?` も `self.has_mask?` も false に
#     なってしまう。
#   - per-element path (fetch_addr が CA_UNDEF を返す) はもう一つ別の
#     コードパスで、ca->mask に直接書く。こちらはちゃんと CAObject 本体に
#     mask が立つ。
#
# このテスト群は observed behavior を pin する。将来 mask propagation が
# 修正された場合は、これらが visibly に通る/落ちる差で気付ける。
# ===========================================================================
class TestMaskBehavior < Test::Unit::TestCase
  # NOTE: observed behavior, may be a real bug (mask propagation gap)
  def test_bulk_path_mask_does_not_propagate_to_result
    a = UndefAtOdd.new(6)
    materialised = a.to_ca
    # 値は UNDEF -> 0 (CA_INT32 default) として落ちる
    assert_equal 0, materialised[0]
    assert_equal 20, materialised[2]
    # mask は伝播しない (= 観察事実、要調査)
    assert_equal false, materialised.has_mask?,
      "observed: bulk-path UNDEF assignment does not propagate mask to to_ca result"
    assert_equal false, a.has_mask?,
      "observed: bulk-path UNDEF does not leave mask on the source CAObject"
  end

  # 単発 fetch_addr 経由の CA_UNDEF は別の code path (ca_ptr_at_addr に直書き)
  def test_per_element_undef_via_single_fetch
    a = UndefAtOdd.new(6)
    GC.start
    # to_ca を呼ばずに単発 [] access で CA_UNDEF 経路を発火
    v0 = a[0]
    v1 = a[1]
    assert_equal 0, v0
    # v1 は UNDEF object (== CA_UNDEF singleton)
    assert v1.is_a?(Object.const_get(:UndefClass))
  end

  # CAObject default の create_mask reject を pin
  # (per-element path で fetch_addr が UNDEF を返した時に発火)
  def test_create_mask_required_for_per_element_undef
    klass = Class.new(CAObject) {
      def initialize; super(CA_INT32, [4]); end
      def fetch_addr(a); UNDEF; end
      def copy_data(d); d.elements.times { |i| d[i] = i; }; end
      # create_mask を **意図的に定義しない**
    }
    no_create = klass.new
    # to_ca 自体は copy_data が走るので例外なし (UNDEF 経路を通らない)
    no_create.to_ca
    # 単発 [] は fetch_addr が UNDEF を返し、mask 作成を試みて raise
    err = assert_raise(RuntimeError) { no_create[0] }
    assert_match(/can't create mask for CAObject/, err.message)
  end

  # GC stress: 多数の CAObject を作って GC を回し、double-free 等が
  # 顕在化しないか
  def test_many_caobjects_gc_stress
    stress_was = GC.stress
    begin
      objs = []
      10.times { objs << UndefAtOdd.new(8) }
      10.times { objs << SquareView.new(CArray.float64(4).seq) }
      GC.start
      objs.each { |o| assert_kind_of Array, o.to_a }
    ensure
      GC.stress = stress_was
    end
  end
end

# ===========================================================================
# 3. fetcher dispatch (片方だけ定義した時の翻訳経路)
# ===========================================================================
class TestFetcherDispatch < Test::Unit::TestCase
  def test_index_only_serves_flat_addr_access
    a = IndexOnlyArr.new([3, 4])
    # flat access が addr -> idx 翻訳で fetch_index に行く
    assert_equal 0,    a[0, 0]
    assert_equal 3,    a[0, 3]
    assert_equal 100,  a[1, 0]
    assert_equal 203,  a[2, 3]
  end

  def test_addr_only_serves_nd_access
    a = AddrOnlyArr.new([2, 3])
    # nd access が idx -> addr 翻訳で fetch_addr に行く
    assert_equal 0,  a[0, 0]
    assert_equal 6,  a[0, 2]
    assert_equal 9,  a[1, 0]
    assert_equal 15, a[1, 2]
  end
end

# ===========================================================================
# 4. read_only / 書き込み禁止
# (FrozenError と RuntimeError の使い分けを pin)
# ===========================================================================
class TestReadOnlyEnforcement < Test::Unit::TestCase
  def test_explicit_read_only_blocks_assignment
    a = AddrOnlyArr.new([4])     # read_only: true で構築
    assert a.read_only?
    assert_raise(RuntimeError) { a[0] = 99 }
  end

  # frozen 由来は **FrozenError**, 自前 read_only: true は **RuntimeError**
  def test_frozen_parent_blocks_assignment_on_derived
    base = CArray.float64(3).seq.freeze
    sq = SquareView.new(base)
    assert_raise(FrozenError) { sq[0] = 0.0 }
  end

  def test_writable_caobject_assigns
    a = MutableObj.new(4)
    a[1] = 42
    assert_equal 42, a[1]
    a[] = 7
    assert_equal [7, 7, 7, 7], a.to_a
  end
end

# ===========================================================================
# 5. dup foot-gun (Ruby Object#dup は ivar を shallow copy するので、
# CAObject 派生で Ruby ivar に backing buffer を置いていると共有される)
# これは bug ではなく Ruby の標準動作だが、CAObject ユーザは混乱しやすい。
# 知っていれば回避できる罠として pin する。
# ===========================================================================
class TestDupSharesIvars < Test::Unit::TestCase
  def test_dup_shares_ruby_ivar_buffer
    a = MutableObj.new(3)
    a[0] = 11; a[1] = 22; a[2] = 33
    b = a.dup
    # @buf は同じ Array (Ruby Object#dup の shallow copy semantics)
    assert_same a.instance_variable_get(:@buf),
                b.instance_variable_get(:@buf)
    # 結果として b への書き込みが a に漏れる
    b[0] = 999
    assert_equal 999, a[0],
      "Object#dup shares ivars; CAObject subclass authors must override " \
      "initialize_copy to deep-copy their state (or document the gotcha)."
  end

  def test_dup_preserves_shape_and_type
    a = AddrOnlyArr.new([3, 4])
    b = a.dup
    assert_equal a.dim, b.dim
    assert_equal a.data_type, b.data_type
  end

  # 2026-05-26 fix: dup で read_only flag が drop していた bug の regression
  def test_dup_preserves_explicit_read_only_flag
    a = AddrOnlyArr.new([3])  # read_only: true で構築
    assert a.read_only?
    b = a.dup
    assert b.read_only?, "dup must preserve CA_FLAG_READ_ONLY from source"
  end

  # 2026-05-26 fix: dup で C-level parent が NULL に reset され、frozen parent
  # 由来の read_only 伝播が壊れていた bug の regression
  def test_dup_preserves_readonly_inherited_from_frozen_parent
    base = CArray.float64(3).seq.freeze
    sq = SquareView.new(base)
    dup = sq.dup
    assert dup.read_only?,
      "dup of CAObject with frozen parent must keep read_only? via C-level parent walk"
    assert_same base, dup.parent
  end

  # clone は frozen も伝える (= Ruby standard semantics)
  def test_clone_preserves_frozen_from_parent
    base = CArray.float64(3).seq.freeze
    sq = SquareView.new(base)
    cl = sq.clone
    assert cl.frozen?
    assert cl.read_only?
  end
end

# ===========================================================================
# 6. Bulk callback fallback (2026-05-26 fix)
# (copy_data / sync_data / fill_data は **optional**。未定義の場合は
#  per-element fetch_addr / store_addr に fallback してループ実行する。
#  最小 `def fetch_addr; end` だけで CAObject が成立する設計を回復。)
# ===========================================================================
class TestBulkCallbackFallback < Test::Unit::TestCase
  def test_to_ca_without_copy_data_uses_per_element_fallback
    a = NoBulkObj.new(5)
    # copy_data 未定義でも fetch_addr ループで bulk 経路が動く
    assert_equal [0, 1, 2, 3, 4], a.to_a
  end

  def test_single_element_fetch_works_without_copy_data
    a = NoBulkObj.new(5)
    assert_equal 0, a[0]
    assert_equal 3, a[3]
  end

  def test_fetch_index_only_supports_to_a_via_fallback
    # fetch_index のみ定義 + copy_data なし → bulk 経路も fallback で動く
    klass = Class.new(CAObject) {
      def initialize; super(CA_INT32, [2, 3], read_only: true); end
      def fetch_index(idx); idx[0] * 10 + idx[1]; end
    }
    a = klass.new
    assert_equal [[0, 1, 2], [10, 11, 12]], a.to_a
  end

  def test_fill_data_fallback_via_store_addr
    # fill_data 未定義 + store_addr 定義 → broadcast write が動く
    klass = Class.new(CAObject) {
      def initialize(n); @buf = Array.new(n, 0); super(CA_INT32, [n]); end
      def fetch_addr(a); @buf[a]; end
      def store_addr(a, v); @buf[a] = v; end
    }
    c = klass.new(4)
    c[] = 7
    assert_equal [7, 7, 7, 7], c.instance_variable_get(:@buf)
  end
end

# ===========================================================================
# 7. Constructor: CA_FIXLEN with bytes=0 is **intentionally accepted**
# (= degenerate edge case の graceful 受容、`spec/Features/feature_extream_spec.rb:32`
#  で正式に pin されている設計契約。CAObject も同じ規則に従う。
#  意図的な対応: 0-byte fixlen は zero_length_dim 等と並ぶ degenerate-but-valid な
#  edge case として受け入れる。実用上は :bytes を必ず明示するのが正しい運用)
# ===========================================================================
class TestConstructorFixlen < Test::Unit::TestCase
  def test_fixlen_without_bytes_accepts_zero_degenerate_case
    klass = Class.new(CAObject) {
      def initialize; super(CA_FIXLEN, [3]); end
      def fetch_addr(a); "x"; end
      def copy_data(d); d.elements.times { |i| d[i] = "x" }; end
    }
    a = klass.new
    # bytes=0 は intentional degenerate case として accept される
    # (= feature_extream_spec.rb と同じ契約)
    assert_equal 0, a.bytes
  end

  def test_fixlen_with_bytes_ok
    klass = Class.new(CAObject) {
      def initialize; super(CA_FIXLEN, [2], bytes: 4); end
      def fetch_addr(a); "abcd"; end
      def copy_data(d); d.elements.times { |i| d[i] = "abcd" }; end
    }
    a = klass.new
    assert_equal 4, a.bytes
    assert_equal CA_FIXLEN, a.data_type
  end

  def test_dim_must_be_array
    assert_raise(TypeError) {
      Class.new(CAObject) {
        def initialize; super(CA_INT32, 3); end   # Array じゃない
        def fetch_addr(a); 0; end
        def copy_data(d); d[] = 0; end
      }.new
    }
  end
end
