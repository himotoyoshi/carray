# frozen_string_literal: true
#
# spec_ai/test_fragrant.rb
#
# コードレビューで発見した「香ばしい」バグに絞ったテスト集。
# 発見したバグはすべて修正済み。全テストが pass する状態。
#
# 実行: ruby spec_ai/test_fragrant.rb
#

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"

# ===========================================================================
# Bug: proc_trim_bang マクロ (carray_generate.c)  [historical]
#
# 旧 hand-written clip!(min, max) で両方指定すると、rmin ループが ptr/m を
# 末尾まで進めた後、rmax ループが同じ変数を使うため配列の範囲外を操作し、
# rmax クランプが実際のデータに適用されない bug があった。
#
# 3.0 で hand-written clip!/clip は retire され、新 clip は mkkernel triop
# + Ruby wrapper (lib/carray/math.rb) で表現される。clip! 自体も
# view-by-default convention で廃止 → `a[] = a.clip(lo, hi)` で代替。
# ここでは regression pin として `a[] = a.clip(...)` 形に書き換え。
# ===========================================================================
class TestTrimBug < Test::Unit::TestCase

  def test_trim_both_bounds
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(0.0, 10.0)
    assert_equal [0.0, 2.0, 8.0, 10.0], a.to_a
  end

  def test_trim_min_only
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(0.0, nil)
    assert_equal [0.0, 2.0, 8.0, 15.0], a.to_a
  end

  def test_trim_max_only
    a = CArray.float(4)
    a[] = [-5.0, 2.0, 8.0, 15.0]
    a[] = a.clip(nil, 10.0)
    assert_equal [-5.0, 2.0, 8.0, 10.0], a.to_a
  end

end

# ===========================================================================
# Bug: rb_ca_each_with_index (carray_loop.c line 242)
#
# each_with_index は非破壊操作なのに rb_ca_modify を呼ぶため、
# frozen 配列で FrozenError になる。
# each, each_addr, each_index は正常 (rb_ca_modify を呼ばない)。
# ===========================================================================
class TestEachWithIndexFrozen < Test::Unit::TestCase

  def setup
    @a = CArray.int(3)
    @a[] = [10, 20, 30]
    @a.freeze
  end

  def test_each_works_on_frozen
    result = []
    assert_nothing_raised { @a.each { |v| result << v } }
    assert_equal [10, 20, 30], result
  end

  # [修正済み] each_with_index が frozen 配列で FrozenError を誤発生させる → rb_ca_modify 削除
  def test_each_with_index_should_work_on_frozen
    result = []
    assert_nothing_raised do
      @a.each_with_index { |val, idx| result << [val, idx] }
    end
    # 3.0: each_with_index yields (elem, idx0, idx1, ...) — individual args
    assert_equal [[10, 0], [20, 1], [30, 2]], result
  end

end

# ===========================================================================
# Bug: ca_object_func_clone (ca_obj_object.c line 398)
#
#   ca_object_new(ca->bytes, ca->ndim, ca->dim, ca->bytes)
#
# 第1引数は data_type (= CA_OBJECT) であるべきところに ca->bytes (= 8 on 64-bit)
# を渡している。data_type=8 は CA_FLOAT64 に相当するため、
# clone が float64 配列になる可能性がある。
# ===========================================================================
class TestCAObjectClone < Test::Unit::TestCase

  # [修正済み] clone の data_type が CA_OBJECT にならない → ca_object_func_clone の第1引数修正
  def test_clone_preserves_data_type
    a = CArray.object(3)
    a[] = [1, "two", :three]
    b = a.clone
    assert_equal a.data_type, b.data_type
    assert b.object?, "clone should still be an object array"
  end

  def test_clone_preserves_contents
    a = CArray.object(3)
    a[] = [1, "hello", :sym]
    b = a.clone
    assert_equal a.to_a, b.to_a
  end

end

# ===========================================================================
# CA_OBJECT 循環参照 と exception safety (carray_core.c)
#
# ca_fetch_addr の構造:
#   ca_test_cyclic_check(ca)  ← 再入検出 (flag が set なら raise)
#   ca_set_cyclic_check(ca)   ← flag を set
#   delegate(fetch)            ← CA_OBJECT は内部で Ruby に戻ることがある
#   ca_clear_cyclic_check(ca) ← flag を clear
#
# 直接自己参照 (a[0]=a):
#   - store は成功 (store 時は test しない)
#   - fetch 時: delegate 中に再度 ca_fetch_addr が呼ばれ、
#     ca_test_cyclic_check が flag 残留を検出して RuntimeError を raise
#   - この raise は set→delegate→clear の delegate 中で起きるため
#     ca_clear_cyclic_check は呼ばれず、flag が永続化する
#
# Exception safety バグ:
#   上記の RuntimeError をキャッチした後、flag が残留しているため
#   その配列への以降の全アクセスが "cyclic reference is not allowed" で失敗する。
#   配列が永久使用不能になる。
# ===========================================================================
class TestCyclicReference < Test::Unit::TestCase

  def test_self_reference_can_be_stored
    a = CArray.object(2)
    a[0] = 42
    # store 時は cyclic check しない → 代入は成功する
    assert_nothing_raised { a[0] = a }
  end

  def test_self_reference_fetch_raises
    a = CArray.object(2)
    a[0] = a
    # fetch 時に再入を検出して RuntimeError を raise する
    assert_raises(RuntimeError) { a[0] }
  end

  # [修正済み] 循環参照エラー後に cyclic_check flag が残留して配列が永久使用不能になる
  # → ca_fetch_addr / ca_fetch_index を rb_protect で包み、例外時も必ず flag をクリア
  def test_array_permanently_broken_after_cyclic_error
    a = CArray.object(2)
    a[0] = a  # 自己参照 (この時点では flag 未セット → 成功)

    begin
      a[0]  # cyclic reference 検出 → RuntimeError, flag 残留
    rescue RuntimeError
    end

    assert_nothing_raised do
      a[0] = 42
    end
    assert_equal 42, a[0]
  end

  # 循環参照でないエラー (範囲外) の後は正常アクセスできる
  def test_array_accessible_after_unrelated_error
    a = CArray.object(2)
    a[0] = 100
    begin
      a[99]  # IndexError
    rescue IndexError, RuntimeError
    end
    # 非循環エラー後は問題なくアクセスできるはず
    assert_equal 100, a[0],
      "array should remain accessible after non-cyclic error"
  end

end
