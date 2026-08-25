# PROPOSAL_PORTABLE_TEXTBOOK_SORT P.6 -- kind: kwarg dispatch for sort_copy.
#
# Scope at landing: sort_copy(kind: :quick | :stable).  sort_index kind:
# is deferred (= argsort is already algorithmically stable via index
# tie-break; the perf-tuning split is future work, see proposal §3.6).
#
# Tests:
#   - default kind == :quick (= byte-equal to no-kwarg form)
#   - kind: :stable preserves equal-key original order
#   - kind: :quick result multiset matches reference Array#sort
#   - kind: <unknown> raises ArgumentError
#   - kind: :stable works on per-axis path (= F.6 fiber engine + aux
#     buffer reused across fibers)

require 'carray'
require 'test/unit'

class TestPortableSortP6 < Test::Unit::TestCase

  # ---------- default + multiset equality ------------------------------

  def test_default_kind_is_quick
    srand(20260612)
    a = CArray.float64(1024) { |i| rand }
    assert_equal a.sort_copy.to_a, a.sort_copy(kind: :quick).to_a
  end

  def test_kind_quick_multiset
    srand(20260613)
    a = CArray.int32(1024) { |i| rand(1000) }
    assert_equal a.to_a.sort, a.sort_copy(kind: :quick).to_a
  end

  def test_kind_stable_multiset
    srand(20260613)
    a = CArray.int32(1024) { |i| rand(1000) }
    assert_equal a.to_a.sort, a.sort_copy(kind: :stable).to_a
  end

  # ---------- stability: alternating duplicates ------------------------

  # On scalar sort the stability witness reduces to whether equal values
  # appear in a contiguous run with predictable ordering; for a pure
  # scalar sort with no tag/index info attached to the value, "stable"
  # vs "unstable" produces visually identical output (all 1.0s followed
  # by all 2.0s).  So this test confirms multiset + sortedness, not the
  # internal property -- argsort stability is exercised in P.4.
  def test_kind_stable_alternating
    n = 1000
    a = CArray.float64(n) { |i| (i % 2 == 0) ? 1.0 : 2.0 }
    expected = Array.new(n / 2, 1.0) + Array.new(n / 2, 2.0)
    assert_equal expected, a.sort_copy(kind: :stable).to_a
    assert_equal expected, a.sort_copy(kind: :quick).to_a
  end

  # ---------- 10 dtype sweep with both kinds ---------------------------

  [:int8, :uint8, :int16, :uint16, :int32, :uint32,
   :int64, :uint64, :float32, :float64].each_with_index do |ctor, idx|
    define_method(:"test_both_kinds_byte_equal_to_ref_#{ctor}") do
      srand(20260700 + idx)
      n = 512
      is_float = [:float32, :float64].include?(ctor)
      arr = CArray.send(ctor, n) { |i|
        is_float ? (rand * 1000.0 - 500.0) : (rand(1000) - (ctor == :int8 ? 50 : 500))
      }
      expected = arr.to_a.sort
      assert_equal expected, arr.sort_copy(kind: :quick).to_a,
                   "kind: :quick dtype=#{ctor}"
      assert_equal expected, arr.sort_copy(kind: :stable).to_a,
                   "kind: :stable dtype=#{ctor}"
    end
  end

  # ---------- per-axis dispatch ----------------------------------------

  def test_kind_stable_per_axis
    # axis: 1 sort per row, kind: :stable: aux buffer reused across
    # fibers (= sort_copy allocates once outside the fiber loop).
    a = CArray.float64(3, 4)
    a[0, nil] = [3.0, 1.0, 4.0, 1.0].to_ca.float64
    a[1, nil] = [5.0, 9.0, 2.0, 6.0].to_ca.float64
    a[2, nil] = [5.0, 3.0, 5.0, 8.0].to_ca.float64
    out = a.sort_copy(axis: 1, kind: :stable)
    assert_equal [1.0, 1.0, 3.0, 4.0], out[0, nil].to_a
    assert_equal [2.0, 5.0, 6.0, 9.0], out[1, nil].to_a
    assert_equal [3.0, 5.0, 5.0, 8.0], out[2, nil].to_a
  end

  def test_kind_quick_per_axis
    a = CArray.float64(3, 4)
    a[0, nil] = [3.0, 1.0, 4.0, 1.0].to_ca.float64
    a[1, nil] = [5.0, 9.0, 2.0, 6.0].to_ca.float64
    a[2, nil] = [5.0, 3.0, 5.0, 8.0].to_ca.float64
    out = a.sort_copy(axis: 1, kind: :quick)
    assert_equal [1.0, 1.0, 3.0, 4.0], out[0, nil].to_a
    assert_equal [2.0, 5.0, 6.0, 9.0], out[1, nil].to_a
    assert_equal [3.0, 5.0, 5.0, 8.0], out[2, nil].to_a
  end

  # ---------- NaN policy preserved for both kinds ----------------------

  def test_kind_stable_nan_at_end_f64
    a = [3.0, Float::NAN, 1.0, Float::NAN, 0.5].to_ca.float64
    out = a.sort_copy(kind: :stable).to_a
    assert_equal [0.5, 1.0, 3.0], out[0..2]
    assert out[3].nan?
    assert out[4].nan?
  end

  def test_kind_quick_nan_at_end_f64
    a = [3.0, Float::NAN, 1.0, Float::NAN, 0.5].to_ca.float64
    out = a.sort_copy(kind: :quick).to_a
    assert_equal [0.5, 1.0, 3.0], out[0..2]
    assert out[3].nan?
    assert out[4].nan?
  end

  # ---------- argument validation --------------------------------------

  def test_unknown_kind_raises
    a = CArray.float64(10).seq
    assert_raise(ArgumentError) { a.sort_copy(kind: :timsort) }
    assert_raise(ArgumentError) { a.sort_copy(kind: :heap) }
  end

end
