# spec_ai/test_sort_kind_kwarg.rb
#
# PROPOSAL_PORTABLE_TEXTBOOK_SORT section 9.5.2 Option gamma acceptance pin.
#
# Contract:
#   sort_addr / sort_index / rank_index / sort_addr accept `kind:` kwarg
#   with values :quick (default) and :stable.  Both algorithms are
#   algorithmically stable (pair sort with index tie-break), so both
#   must produce identical output on the same input.  kind: chooses the
#   performance characteristic only.
#
#   Unknown kind raises ArgumentError.
#
#   Existing arity-1 _ki Ruby surfaces (sort_index_ki(axis),
#   rank_index_ki(axis)) keep working unchanged and default to quick.

require "test/unit"
require "carray"

class TestSortKindKwarg < Test::Unit::TestCase

  def setup
    @arr_random = CA_INT32([5, 2, 8, 1, 9, 3, 2, 7, 4, 6])
    @arr_ties   = CA_INT32([5, 2, 8, 2, 5, 2, 8, 2, 5, 8])
    @arr_2d     = CA_INT32([[3, 1, 4, 1, 5],
                            [9, 2, 6, 5, 3],
                            [5, 8, 9, 7, 9]])
    @arr_float_nan = CA_FLOAT64([1.0, Float::NAN, 3.0, 2.0, Float::NAN, 0.5])
  end

  # ---- sort_index ------------------------------------------------------

  def test_sort_index_kind_quick_returns_same_as_default
    assert_equal @arr_random.sort_index(axis: 0).to_a,
                 @arr_random.sort_index(axis: 0, kind: :quick).to_a
  end

  def test_sort_index_kind_stable_returns_same_ordering_as_quick
    # Both are algorithmically stable -> identical output
    q = @arr_random.sort_index(axis: 0, kind: :quick).to_a
    s = @arr_random.sort_index(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_sort_index_kind_stable_ties_match_quick
    q = @arr_ties.sort_index(axis: 0, kind: :quick).to_a
    s = @arr_ties.sort_index(axis: 0, kind: :stable).to_a
    assert_equal q, s, "tie-heavy input must give identical output"
  end

  def test_sort_index_kind_stable_2d_axis
    q = @arr_2d.sort_index(axis: 1, kind: :quick).to_a
    s = @arr_2d.sort_index(axis: 1, kind: :stable).to_a
    assert_equal q, s
  end

  def test_sort_index_kind_unknown_raises
    assert_raise(ArgumentError) do
      @arr_random.sort_index(axis: 0, kind: :bogus)
    end
  end

  def test_sort_index_legacy_ki_still_arity_1
    # Existing callers (= spec_ai using .sort_index_ki(axis)) continue.
    assert_nothing_raised do
      result = @arr_random.sort_index_ki(0)
      assert_equal @arr_random.sort_index(axis: 0, kind: :quick).to_a,
                   result.to_a
    end
  end

  # ---- rank_index ------------------------------------------------------

  def test_rank_index_kind_quick_default
    assert_equal @arr_random.rank_index(axis: 0).to_a,
                 @arr_random.rank_index(axis: 0, kind: :quick).to_a
  end

  def test_rank_index_kind_stable_matches_quick
    q = @arr_random.rank_index(axis: 0, kind: :quick).to_a
    s = @arr_random.rank_index(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_rank_index_kind_stable_ties_match
    q = @arr_ties.rank_index(axis: 0, kind: :quick).to_a
    s = @arr_ties.rank_index(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_rank_index_kind_unknown_raises
    assert_raise(ArgumentError) do
      @arr_random.rank_index(axis: 0, kind: :wat)
    end
  end

  def test_rank_index_legacy_ki_arity_1
    assert_equal @arr_random.rank_index(axis: 0, kind: :quick).to_a,
                 @arr_random.rank_index_ki(0).to_a
  end

  # ---- sort (= rb_ca_sorted_view) -------------------------------------

  def test_sort_kind_quick_default
    assert_equal @arr_random.sort(axis: 0).to_a,
                 @arr_random.sort(axis: 0, kind: :quick).to_a
  end

  def test_sort_kind_stable_matches_quick
    q = @arr_random.sort(axis: 0, kind: :quick).to_a
    s = @arr_random.sort(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_sort_kind_stable_no_axis_flatten
    # No-arg form flattens then sorts axis 0.  kind: still accepted.
    q = @arr_2d.sort(kind: :quick).to_a
    s = @arr_2d.sort(kind: :stable).to_a
    assert_equal q, s
    assert_equal @arr_2d.to_a.flatten.sort, q
  end

  def test_sort_kind_unknown_raises
    assert_raise(ArgumentError) do
      @arr_random.sort(kind: :bogus)
    end
  end

  def test_sort_kind_nan_at_end_preserved
    # Both kinds preserve the NaN-at-end policy from the underlying
    # ca_partition_nan_pair_<src> pre-pass.
    q = @arr_float_nan.sort(axis: 0, kind: :quick).to_a
    s = @arr_float_nan.sort(axis: 0, kind: :stable).to_a
    # Finite prefix sorted ascending, NaN tail count preserved
    finite_q = q.reject { |x| x.nan? }
    finite_s = s.reject { |x| x.nan? }
    nan_q    = q.count { |x| x.nan? }
    nan_s    = s.count { |x| x.nan? }
    assert_equal [0.5, 1.0, 2.0, 3.0], finite_q
    assert_equal [0.5, 1.0, 2.0, 3.0], finite_s
    assert_equal 2, nan_q
    assert_equal 2, nan_s
  end

  # ---- sort_addr -------------------------------------------------------

  def test_sort_addr_kind_quick_default
    assert_equal @arr_random.sort_addr(axis: 0).to_a,
                 @arr_random.sort_addr(axis: 0, kind: :quick).to_a
  end

  def test_sort_addr_kind_stable_matches_quick
    q = @arr_random.sort_addr(axis: 0, kind: :quick).to_a
    s = @arr_random.sort_addr(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_sort_addr_kind_stable_ties_match
    q = @arr_ties.sort_addr(axis: 0, kind: :quick).to_a
    s = @arr_ties.sort_addr(axis: 0, kind: :stable).to_a
    assert_equal q, s
  end

  def test_sort_addr_kind_unknown_raises
    assert_raise(ArgumentError) do
      @arr_random.sort_addr(axis: 0, kind: :nope)
    end
  end

  def test_sort_addr_no_axis_legacy_ignores_kind
    # The no-axis flat form (= CArray.sort_addr(self) legacy) ignores kind:
    # but must not raise.
    assert_nothing_raised do
      @arr_random.sort_addr  # 1-D flat output
    end
  end

  # ---- larger random regression ---------------------------------------

  def test_quick_and_stable_agree_on_large_random
    srand(0xCAFE)
    n   = 5000
    arr = CA_INT32(Array.new(n) { rand(50) })   # many ties
    q = arr.sort_index(axis: 0, kind: :quick).to_a
    s = arr.sort_index(axis: 0, kind: :stable).to_a
    assert_equal q, s, "5000-element tie-heavy sort_index quick vs stable"

    q2 = arr.sort_addr(axis: 0, kind: :quick).to_a
    s2 = arr.sort_addr(axis: 0, kind: :stable).to_a
    assert_equal q2, s2

    q3 = arr.rank_index(axis: 0, kind: :quick).to_a
    s3 = arr.rank_index(axis: 0, kind: :stable).to_a
    assert_equal q3, s3
  end

  def test_quick_and_stable_agree_per_axis_2d
    srand(0xBEEF)
    arr = CA_INT32(Array.new(8) { Array.new(64) { rand(30) } })
    [0, 1].each do |ax|
      q = arr.sort_index(axis: ax, kind: :quick).to_a
      s = arr.sort_index(axis: ax, kind: :stable).to_a
      assert_equal q, s, "2D axis=#{ax} sort_index quick vs stable"
    end
  end

end
