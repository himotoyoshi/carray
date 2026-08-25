require "test/unit"
require_relative "../../lib/carray"

# ca_iter_*.c の initialize_copy バグを検証するテスト
#
# バグ概要（3ファイル共通）:
#   Ruby 規約: initialize_copy(other) において
#     self  = 新オブジェクト（コピー先）
#     other = 元オブジェクト（コピー元）
#
#   ca_iter_block.c (rb_bi_initialize_copy):
#     誤: ca_bi_setup(other, ivar_get(self, @ref), ivar_get(self, @ker))
#         → other (元) が nil の引数で setup される
#         → self (コピー先) には何も設定されない
#     正: ca_bi_setup(self, ivar_get(other, @ref), ivar_get(other, @ker))
#
#   ca_iter_window.c (rb_vi_initialize_copy): 同パターン
#
#   ca_iter_dimension.c (rb_di_initialize_copy):
#     誤: rref = ivar_get(self, @reference)  → nil (self は空)
#         *io = *is  → other(元) の C 構造体を new(空) で上書き → 元を破壊!
#         ivar_set(self, @reference, nil)  → コピーに nil をセット
#     正: rref = ivar_get(other, @reference)
#         *is = *io
#         ivar_set(self, @reference, rref)
#
# テスト戦略:
#   - each を呼ぶと壊れた copy でクラッシュするので、修正前は each を使わない
#   - Ruby レベルの ivar (@reference, @kernel) が正しいかチェック
#   - 修正前: @reference が nil になる → assert_not_nil が失敗 (no crash)
#   - 修正後: 全テストが pass する
#
# 修正後の動作確認テスト (each を使う) は test_iterators_post_fix.rb で行う

# CABlockIterator is now a plain Ruby object (lib/carray/block_iterator.rb),
# so dup is trivially safe; the old C-struct dup bugs no longer apply.
class TestCABlockIteratorDup < Test::Unit::TestCase

  def setup
    @a = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @iter = @a.blocks(0..1)   # size-2 tiles, 3 tiles
  end

  def test_dup_does_not_raise
    assert_nothing_raised { @iter.dup }
  end

  def test_copy_has_source
    copy = @iter.dup
    assert_equal @a.object_id, copy.source.object_id
  end

  def test_copy_iterates_like_original
    copy = @iter.dup
    assert_equal @iter.mean.to_a, copy.mean.to_a
  end

  def test_original_unaffected_after_dup
    @iter.dup
    assert_equal @a.object_id, @iter.source.object_id
  end

end

# CAWindowIterator is now a plain Ruby object (lib/carray/window_iterator.rb),
# so dup is trivially safe; the old C-struct dup bugs no longer apply.
class TestCAWindowIteratorDup < Test::Unit::TestCase

  def setup
    @a = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @iter = @a.windows(-1..1)   # width-3 window
  end

  def test_dup_does_not_raise
    assert_nothing_raised { @iter.dup }
  end

  def test_copy_has_source
    copy = @iter.dup
    assert_equal @a.object_id, copy.source.object_id
  end

  def test_copy_iterates_like_original
    copy = @iter.dup
    assert_equal @iter.mean.to_a, copy.mean.to_a
  end

  def test_original_unaffected_after_dup
    @iter.dup
    assert_equal @a.object_id, @iter.source.object_id
  end

end

# SI.3: CADimensionIterator retired -> CASlabIterator (a plain Ruby object,
# so dup is trivially safe; the old C-struct dup bugs no longer apply).
class TestCASlabIteratorDup < Test::Unit::TestCase

  def setup
    @a = CArray.int(3, 4).tap { |__a| __a[] = [*1..12] }
    @iter = @a[nil, :>]   # row iterator (slab axis 1, outer axis 0)
  end

  def test_dup_does_not_raise
    assert_nothing_raised { @iter.dup }
  end

  def test_copy_has_reference
    copy = @iter.dup
    assert_not_nil copy.instance_variable_get(:@reference)
  end

  def test_copy_preserves_slab_axes
    copy = @iter.dup
    assert_equal @iter.slab_axes, copy.instance_variable_get(:@slab_axes)
  end

end
