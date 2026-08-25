require "test/unit"
require "carray"

# PROPOSAL_RUBBER_SIGIL (RB.1-RB.3): :~ = unified auto-fill sigil.
#   indexer : ellipsis (= false synonym, fill remaining axes)
#   reshape : infer    (= -1 synonym, infer one dim's size)
# false / -1 retained (non-breaking); :~ is the recommended spelling.

class TestRubberSigilIndexer < Test::Unit::TestCase

  def setup
    @a = CArray.int32(2, 3, 4).seq   # 24
  end

  # AC1: indexer ellipsis == false
  def test_ellipsis_equals_false
    got = []
    @a[:~, :>].each { |s| got << s.to_a }
    ref = []
    @a[false, :>].each { |s| ref << s.to_a }
    assert_equal ref, got
  end

  # AC2: :~ composes with :> slab (ndim-agnostic rest+slab)
  def test_ellipsis_plus_slab
    got = []
    @a[:~, :>, :>].each { |s| got << s.dim }
    ref = []
    @a.each_slab(axis: [-2, -1]) { |s| ref << s.dim }
    assert_equal ref, got
  end

  # AC3: single ca[:~] == ca[false] == ca[]
  def test_single_all
    assert_equal @a[].to_a,      @a[:~].to_a
    assert_equal @a[false].to_a, @a[:~].to_a
    assert_equal @a.dim,         @a[:~].dim
  end

  # AC4: newaxis (:_) × rubber (:~) mix -> IndexError
  def test_newaxis_rubber_mix_raises
    assert_raise(IndexError) { @a[:_, :~] }
  end
end

class TestRubberSigilReshape < Test::Unit::TestCase

  def setup
    @a = CArray.int32(2, 3, 4).seq   # 24
  end

  # AC5: reshape infer == -1
  def test_infer_equals_minus_one
    assert_equal @a.reshape(-1, 3, 2).dim, @a.reshape(:~, 3, 2).dim
    assert_equal @a.reshape(4, -1).dim,    @a.reshape(4, :~).dim
    assert_equal [4, 3, 2], @a.reshape(:~, 3, 2).dim
  end

  # AC6: two infer placeholders -> RuntimeError (same as two -1)
  def test_two_placeholders_raise
    assert_raise(RuntimeError) { @a.reshape(:~, :~) }
    assert_raise(RuntimeError) { @a.reshape(:~, -1) }   # mixed also one-too-many
  end

  # AC7: :~ / nil mix == -1 / nil mix, always element-preserving
  def test_infer_nil_mix
    assert_equal @a.reshape(nil, -1).dim, @a.reshape(nil, :~).dim   # [2,12]
    assert_equal @a.reshape(-1, nil).dim, @a.reshape(:~, nil).dim   # [6,4]
    assert_equal 24, @a.reshape(nil, :~).elements
    assert_equal 24, @a.reshape(:~, nil).elements
  end

  # infer must divide evenly
  def test_infer_non_divisible_raises
    assert_raise(RuntimeError) { @a.reshape(:~, 5) }   # 24 % 5 != 0
  end
end

class TestRubberSigilNonBreaking < Test::Unit::TestCase
  # AC8: false / -1 paths unchanged
  def test_false_still_works
    a = CArray.int32(2, 3, 4).seq
    got = []
    a[false, :>].each { |s| got << s.dim }
    assert_equal 6, got.size   # 2*3 outer positions
  end

  def test_minus_one_still_works
    a = CArray.int32(2, 3, 4).seq
    assert_equal [4, 3, 2], a.reshape(-1, 3, 2).dim
  end
end
