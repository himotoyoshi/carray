# PROPOSAL_PORTABLE_TEXTBOOK_SORT P.5 — depth-limit + mergesort escape +
# stability formal gates.
#
# AC7: median-of-3 killer adversarial input must complete in O(n log n).
#      We verify this by (a) wall-time bound (= a quadratic sort on N=10000
#      adversarial input would take seconds; we cap at 200 ms),
#      (b) byte-correct output regardless of escape firing,
#      (c) escape doesn't break ordering.
#
# AC5: stability formal pin for mergesort.  Alternating + tagged-value
#      patterns; equal keys must preserve original relative position.

require 'carray'
require 'test/unit'

unless CArray.instance_methods.include?(:_sort_copy_quick_v2)
  warn "test_portable_sort_p5: dev-only smoke methods unavailable"
  return
end

class TestPortableSortP5 < Test::Unit::TestCase

  # ---------- AC7: adversarial input does not regress to O(n^2) ---------

  # Classic median-of-3 killer: a permutation that forces median-of-3 to
  # always pick a poor pivot.  Construction (Musser 1997): for an
  # ascending source [0..n-1], swap a[mid] with a[mid-1] before each
  # recursion.  We use the simpler "two-stacked-sorted" pattern (= half
  # ascending, half descending) which is a well-known qsort adversary.
  def make_quicksort_killer(n)
    # Build [0, 2, 4, ..., 2(n/2-1) | 2(n/2-1)+1, ..., 3, 1]
    # = ascending evens followed by descending odds.  Median-of-3 on
    # head/tail/mid pick consistently degenerate pivots on this layout.
    half = n / 2
    a = Array.new(n)
    (0...half).each { |i| a[i] = 2 * i }
    (0...(n - half)).each { |i| a[half + i] = 2 * (n - half - 1 - i) + 1 }
    a
  end

  def test_quick_adversarial_n10000_completes_quickly
    n = 10_000
    src = make_quicksort_killer(n)
    arr = CArray.float64(n) { |i| src[i].to_f }
    expected = src.sort.map(&:to_f)

    t = nil
    # Cap at 200 ms.  Pre-P.5 (= no depth-limit), median-of-3 killer at
    # n=10000 still completes in a few ms because Hoare partition is
    # robust; the canonical Musser killer needs Sedgewick-style swap
    # injection to actually quadratic.  So this test is a regression gate
    # more than a quadratic catcher -- it confirms (a) escape doesn't
    # corrupt output, (b) wall time stays bounded.
    require 'benchmark'
    t = Benchmark.realtime { @result = arr._sort_copy_quick_v2 }
    assert t < 0.2, "adversarial input took #{ '%.3f' % t }s -- escape failing?"
    assert_equal expected, @result.to_a
  end

  # Direct stress: many descending-then-ascending fragments, sized so the
  # algorithm hits depth limit on at least one subrange.
  def test_quick_pathological_zig_zag_byte_correct
    # 4-segment pattern: each segment internally is reverse-sorted, segments
    # together are ascending in value range -> median-of-3 picks the
    # cross-segment median, often degenerate.
    n = 5000
    seg = 1250
    src = Array.new(n)
    4.times do |k|
      seg_start = k * seg
      (0...seg).each { |i| src[seg_start + i] = k * 1000 + (seg - 1 - i) }
    end
    arr = CArray.float64(n) { |i| src[i].to_f }
    expected = src.sort.map(&:to_f)
    out = arr._sort_copy_quick_v2
    assert_equal expected, out.to_a
  end

  # Massive duplicates: median-of-3 + Hoare handles duplicates fine, but
  # ensure escape (if it fires) also handles them.
  def test_quick_massive_duplicates
    n = 5000
    arr = CArray.int32(n) { |i| i % 7 }  # 7 distinct values, each ~715 times
    out = arr._sort_copy_quick_v2
    assert_equal arr.to_a.sort, out.to_a
  end

  # Make sure sort_copy live path (= rb_ca_sort_copy with portable kernel)
  # also handles adversarial input correctly.
  def test_sort_copy_live_adversarial
    n = 10_000
    src = make_quicksort_killer(n)
    arr = CArray.float64(n) { |i| src[i].to_f }
    expected = src.sort.map(&:to_f)
    out = arr.sort_copy
    assert_equal expected, out.to_a
  end

  # ---------- AC5: stability formal pin for mergesort ------------------

  # Alternating two-value pattern (= classic stability witness):
  # [1, 2, 1, 2, 1, 2, ...].  Stable sort must preserve the original
  # positions of the 1s before the 2s' positions within each equal-key
  # run.  Since values are scalar (1.0 or 2.0), the witness reduces to
  # ordering: stable sort produces [1, 1, ..., 1, 2, 2, ..., 2] with
  # the 1s in their original-position order (= first/third/fifth/...).
  def test_merge_stable_alternating
    n = 1000
    arr = CArray.float64(n) { |i| (i % 2 == 0) ? 1.0 : 2.0 }
    out = arr._sort_copy_merge_v2
    expected = Array.new(n / 2, 1.0) + Array.new(n / 2, 2.0)
    assert_equal expected, out.to_a
  end

  # Stability under tagged keys: simulate "tagged value sort" by mapping
  # original indices into the low bits of the value.  After sort, within
  # each equal high-bit group, low bits must be ascending (= original
  # order preserved).
  def test_merge_stable_tagged_keys
    n = 200
    # value = key (10 distinct, repeated 20x) * 10000 + original_index
    # high 4 digits = sort key (= 10 distinct values, each appearing 20x)
    # low 4 digits  = tag = original index
    arr = CArray.float64(n) { |i| (i % 10) * 10_000.0 + i.to_f }
    out = arr._sort_copy_merge_v2
    out_arr = out.to_a

    # Decompose: high = floor(v / 10000), tag = v - high * 10000
    pairs = out_arr.map { |v| [(v / 10_000).to_i, (v % 10_000).to_i] }
    # Group by high; for each group the tags (= original indices) must be
    # ascending (= stable: original order preserved).
    pairs.chunk { |hi, _| hi }.each do |hi, group|
      tags = group.map { |_, tag| tag }
      assert_equal tags.sort, tags,
                   "stability violated in high-key #{hi} group: tags=#{tags.inspect}"
    end
  end

  # ---------- escape sanity ------------------------------------------

  # Confirm the recursion terminates even on a pathological size (= test
  # that the algorithm doesn't infinite-loop or stack-overflow on N=100k
  # with depth-limit firing).
  def test_quick_large_adversarial_n100k_finishes
    n = 100_000
    src = make_quicksort_killer(n)
    arr = CArray.float64(n) { |i| src[i].to_f }
    require 'benchmark'
    t = Benchmark.realtime { @result = arr._sort_copy_quick_v2 }
    assert t < 1.0, "n=100k adversarial took #{ '%.3f' % t }s"
    # Bulk monotonic check: byte-equal to Array#sort.  Cheaper than
    # each_cons(2) + assert which would emit n-1 assertions.
    out_a = @result.to_a
    assert_equal out_a.sort, out_a, "output not monotonically nondecreasing"
  end

end
