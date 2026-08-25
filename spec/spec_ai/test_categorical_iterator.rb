# Test for CArray#group_by_category / CACategoricalIterator (per-category
# reduction dispatcher, Phase 1.5 Ruby productionization).
# See devel/PROPOSAL_CACATEGORICAL_ITERATOR.md.
#
# Contract: each group is delegated to the same-named CArray reduction over the
# group's members, so a group result equals CArray#<reduction> for those
# members. The mask contract flows through: an empty or fully-masked group
# reduces like an empty array -- identity for sum (0), UNDEF for mean / median /
# variance; a single-value group has variance / stddev 0.0 (CArray's n=1
# contract). elements counts classified cells (incl. value-masked);
# count_not_masked counts present cells (the reduction denominator).
#
# Exercises the autoload wiring too (plain `require "carray"`).

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestCategoricalIterator < Test::Unit::TestCase

  # ---- brute-force Ruby references (match CArray's contract) ----------------

  def brute_groups(keys, values, labels, excluded = [])
    groups = {}
    labels.each { |l| groups[l] = [] }
    keys.each_with_index do |k, j|
      next if excluded.include?(j)
      next unless groups.key?(k)
      groups[k] << values[j]
    end
    groups
  end

  # sample variance/stddev with CArray's edge contract: n==0 -> masked,
  # n==1 -> 0.0, n>=2 -> sample (ddof=1).
  def ref_variance(a)
    n = a.size
    return :masked if n == 0
    return 0.0 if n == 1
    m = a.sum.to_f / n
    a.sum { |x| (x - m)**2 } / (n - 1)
  end

  def ref_stddev(a)
    v = ref_variance(a)
    v == :masked ? :masked : Math.sqrt(v)
  end

  def ref_median(a)
    return :masked if a.empty?
    s = a.sort
    n = s.size
    n.odd? ? s[n / 2].to_f : (s[n / 2 - 1] + s[n / 2]) / 2.0
  end

  # assert a length-k result against per-label reference values, where a
  # reference of :masked means the cell must be masked.
  def assert_group(result, refs, delta: 1e-12)
    refs.each_with_index do |r, i|
      if r == :masked
        assert_equal true, result.is_masked[i], "slot #{i} should be masked"
      else
        assert_equal false, result.is_masked[i], "slot #{i} should be present"
        assert_in_delta r, result[i], delta, "slot #{i}"
      end
    end
  end

  # ---- autoload -------------------------------------------------------------

  def test_autoload_via_plain_require
    cat = CA_OBJECT(%w[a b a]).categorize
    grp = CA_DOUBLE([1, 2, 3]).group_by_category(cat)
    assert_kind_of CACategoricalIterator, grp
    assert_kind_of CAIterator, grp
  end

  # ---- Case 1: all valid, first-appearance labels ---------------------------

  def test_case1_all_valid
    keys   = %w[b a b c a b]
    values = [10, 20, 30, 40, 50, 60]
    cat    = CA_OBJECT(keys).categorize
    grp    = CA_DOUBLE(values).group_by_category(cat)

    assert_equal %w[b a c], grp.labels
    labels = grp.labels
    ref    = brute_groups(keys, values, labels)

    assert_equal labels.map { |l| ref[l].size },     grp.elements.to_a
    assert_group grp.sum,      labels.map { |l| ref[l].sum.to_f }
    assert_group grp.max,      labels.map { |l| ref[l].max.to_f }
    assert_group grp.min,      labels.map { |l| ref[l].min.to_f }
    assert_group grp.mean,     labels.map { |l| ref[l].sum.to_f / ref[l].size }
    assert_group grp.median,   labels.map { |l| ref_median(ref[l]) }
    # group 'c' is a singleton -> variance/stddev 0.0 (not masked)
    assert_group grp.variance, labels.map { |l| ref_variance(ref[l]) }
    assert_group grp.stddev,   labels.map { |l| ref_stddev(ref[l]) }
  end

  def test_case1_output_dtypes
    cat = CA_OBJECT(%w[b a b c a b]).categorize
    grp = CA_INT32([10, 20, 30, 40, 50, 60]).group_by_category(cat)
    assert_equal CA_INT64,   grp.elements.data_type
    assert_equal CA_INT64,   grp.count_not_masked.data_type
    assert_equal CA_INT32,   grp.sum.data_type    # value dtype
    assert_equal CA_INT32,   grp.max.data_type    # value dtype
    assert_equal CA_INT32,   grp.min.data_type    # value dtype
    assert_equal CA_FLOAT64, grp.mean.data_type
    assert_equal CA_FLOAT64, grp.median.data_type
    assert_equal CA_FLOAT64, grp.stddev.data_type
    assert_equal CA_FLOAT64, grp.variance.data_type
  end

  # ---- Case 2: out-of-vocab excluded + empty category -----------------------

  def test_case2_excluded_and_empty
    keys   = %w[x y z x q x]                                # 'q' out-of-vocab
    values = [1, 2, 3, 4, 5, 6]
    cat    = CA_OBJECT(keys).categorize(labels: %w[x y z w]) # 'w' empty
    grp    = CA_DOUBLE(values).group_by_category(cat)

    assert_equal %w[x y z w], grp.labels
    assert_equal [3, 1, 1, 0], grp.elements.to_a               # 'q' skipped

    # empty category 'w' == empty array: sum -> 0 (identity, unmasked),
    # mean / median -> masked.
    assert_group grp.sum,    [1 + 4 + 6, 2, 3, 0]
    assert_equal false, grp.sum.is_masked[3]
    assert_equal true, grp.mean.is_masked[3]
    assert_equal true, grp.median.is_masked[3]
    assert_in_delta (1 + 4 + 6) / 3.0, grp.mean[0], 1e-12
    assert_in_delta ref_median([1, 4, 6]), grp.median[0], 1e-12
  end

  # ---- ddof consistency: group == flat CArray#stddev/#variance --------------

  def test_ddof_matches_flat_single_category
    values = CA_DOUBLE([2, 4, 6, 8, 11])
    cat    = CA_OBJECT(%w[g g g g g]).categorize
    grp    = values.group_by_category(cat)
    assert_in_delta values.stddev,   grp.stddev[0],   1e-12
    assert_in_delta values.variance, grp.variance[0], 1e-12
  end

  # ---- single-value group: variance/stddev 0.0 (matches CArray n=1) ---------

  def test_single_value_group_variance_is_zero
    # 'a' has 1 element -> 0.0 (not masked); 'b' has 2 -> defined; empty -> masked
    cat = CA_OBJECT(%w[a b b]).categorize(labels: %w[a b c])
    grp = CA_DOUBLE([5, 10, 20]).group_by_category(cat)
    assert_group grp.variance, [0.0, ref_variance([10, 20]), :masked]
    assert_group grp.stddev,   [0.0, ref_stddev([10, 20]),   :masked]
    # matches flat CArray on the singleton
    assert_equal false, grp.variance.is_masked[0]
    assert_in_delta CA_DOUBLE([5]).variance, grp.variance[0], 1e-12
  end

  # ---- value carries a mask: elements vs count_not_masked, mean denominator ----

  def test_masked_value_count_and_mean
    # 'a' = [10, _, 30] (one value masked); 'b' = [40]
    keys = %w[a a a b]
    vals = CA_DOUBLE([10, 20, 30, 40]); vals[1] = UNDEF
    cat  = CA_OBJECT(keys).categorize(labels: %w[a b])
    grp  = vals.group_by_category(cat)

    assert_equal [3, 1], grp.elements.to_a             # classified cells (incl. masked)
    assert_equal [2, 1], grp.count_not_masked.to_a  # present cells
    assert_equal [1, 0], grp.count_masked.to_a
    # sum / mean skip the masked value; mean divides by count_not_masked (2)
    assert_group grp.sum,  [10 + 30, 40]
    assert_group grp.mean, [(10 + 30) / 2.0, 40.0]
  end

  def test_all_value_masked_group
    # 'a' fully value-masked (n=0 present), 'b' present
    keys = %w[a a b]
    vals = CA_DOUBLE([10, 20, 30]); vals[0] = UNDEF; vals[1] = UNDEF
    cat  = CA_OBJECT(keys).categorize(labels: %w[a b])
    grp  = vals.group_by_category(cat)

    assert_equal [2, 1], grp.elements.to_a
    assert_equal [0, 1], grp.count_not_masked.to_a
    # all-masked group reduces like an empty one: sum -> 0 (identity, unmasked),
    # mean / variance -> masked
    assert_group grp.sum,  [0.0, 30.0]
    assert_equal false, grp.sum.is_masked[0]
    assert_equal true, grp.mean.is_masked[0]
    assert_equal true, grp.variance.is_masked[0]
  end

  # ---- masked-valid-code: mask authoritative, not `code < k` ----------------

  def test_masked_valid_code_excluded
    codes = CA_UINT8([0, 1, 0, 1, 0, 1])
    codes.mask = CA_BOOLEAN([0, 0, 1, 0, 0, 0])   # mask j=2 (valid code 0)
    cat = CACategorical.from_codes(codes, %w[a b])
    grp = CA_DOUBLE([10, 20, 30, 40, 50, 60]).group_by_category(cat)

    assert_equal false, cat.codes.is_not_masked[2]     # j=2 excluded
    assert_equal [2, 3], grp.elements.to_a            # a={j0,j4}, b={j1,j3,j5}
    assert_group grp.sum, [10 + 50, 20 + 40 + 60]
  end

  # ---- edge cases -----------------------------------------------------------

  def test_all_excluded
    codes = CA_UINT8([255, 255, 255])              # all sentinel -> all excluded
    cat   = CACategorical.from_codes(codes, %w[a b])
    grp   = CA_DOUBLE([1, 2, 3]).group_by_category(cat)

    assert_equal 2, grp.elements.elements             # length == k
    assert_equal [0, 0], grp.elements.to_a
    assert_group grp.sum,  [0.0, 0.0]              # empty -> 0 (identity)
    assert_equal [true, true], grp.mean.is_masked.to_a  # mean masked (undefined)
    assert_equal [true, true], grp.median.is_masked.to_a
  end

  def test_single_category
    cat = CA_OBJECT(%w[g g g g]).categorize
    grp = CA_DOUBLE([2, 4, 6, 8]).group_by_category(cat)
    assert_equal %w[g], grp.labels
    assert_equal [4], grp.elements.to_a
    assert_in_delta 5.0, grp.mean[0], 1e-12
  end

  def test_length_equals_k_and_aligned_to_labels
    cat = CA_OBJECT(%w[c a b a c c]).categorize(labels: %w[a b c d])
    grp = CA_DOUBLE([1, 2, 3, 4, 5, 6]).group_by_category(cat)
    k = cat.labels.size
    assert_equal 4, k
    [grp.elements, grp.count_not_masked, grp.sum, grp.max, grp.min, grp.mean,
     grp.median, grp.stddev, grp.variance].each do |r|
      assert_equal k, r.elements
    end
    assert_equal %w[a b c d], grp.labels
    assert_equal true, grp.mean.is_masked[3]          # 'd' empty -> masked
    assert_equal 0, grp.elements[3]
  end

  def test_sizes_equals_bincount_and_count_not_masked
    cat = CA_OBJECT(%w[c a b a c c]).categorize(labels: %w[a b c d])
    grp = CA_DOUBLE([1, 2, 3, 4, 5, 6]).group_by_category(cat)
    assert_equal cat.category_sizes.to_a, grp.elements.to_a
    # no value mask -> count_not_masked == elements
    assert_equal grp.elements.to_a, grp.count_not_masked.to_a
  end

  # ---- surface guards -------------------------------------------------------

  def test_elements_mismatch_raises
    cat = CA_OBJECT(%w[a b]).categorize
    assert_raise(ArgumentError) do
      CA_DOUBLE([1, 2, 3]).group_by_category(cat)
    end
  end

  def test_percentile
    cat    = CA_OBJECT(%w[a a a a a]).categorize
    values = CA_DOUBLE([1, 2, 3, 4, 5])
    grp    = values.group_by_category(cat)
    assert_in_delta values.percentile(25),  grp.percentile(25)[0],  1e-12
    assert_in_delta values.percentile(50),  grp.percentile(50)[0],  1e-12
    assert_in_delta values.median,          grp.median[0],          1e-12
    assert_in_delta values.percentile(100), grp.percentile(100)[0], 1e-12
  end

  def test_quantile_is_five_number_summary
    # quantile (no argument) is the five-number summary, matching CArray#quantile
    # -- no collision. The single-fraction case stays percentile(q*100).
    cat = CA_OBJECT(%w[a a b]).categorize
    grp = CA_DOUBLE([1, 2, 3]).group_by_category(cat)
    assert grp.respond_to?(:quantile)
    assert_equal 5, grp.quantile.size                        # [min, Q1, median, Q3, max]
  end

  def test_nd_value_and_keys_are_raveled
    keys = CA_OBJECT([%w[a b], %w[b a]])           # 2x2
    vals = CA_DOUBLE([[1, 2], [3, 4]])
    cat  = keys.categorize
    grp  = vals.group_by_category(cat)
    assert_equal %w[a b], grp.labels
    assert_equal [2, 2], grp.elements.to_a            # a={(0,0),(1,1)}, b={(0,1),(1,0)}
    assert_group grp.sum, [1 + 4, 2 + 3]
  end

  # ---- differential drift anchor --------------------------------------------

  # The iterator's C reduceat kernels reimplement the reduction contract
  # independently of core, so two independent implementations of one contract now
  # exist. Assert they agree with core CArray reductions applied to the same group
  # members (masked values and an empty category included), so a future drift in
  # either contract fails here. See CLAUDE.md "reduction / order 統計は寄与ゼロで
  # raise しない".
  def test_reduceat_agrees_with_core_per_segment
    keys = CA_INT32(2000) { |i| (i * 7) % 40 }
    val  = CA_DOUBLE(2000) { |i| ((i * 131 + 7) % 997).to_f }
    val[val.lt(30.0)] = UNDEF                          # some masked values
    cat  = keys.categorize(labels: (0..40).to_a)       # label 40 -> empty category
    grp  = val.group_by_category(cat)
    members = grp.labels.map { |lab| val[cat.eq(lab)] } # each group's value cells

    agree = lambda do |got, &core|
      grp.labels.each_index do |i|
        r = core.call(members[i])
        if r.equal?(UNDEF)
          assert_equal true, got.is_masked[i], "slot #{i} should be masked"
        else
          assert_equal false, got.is_masked[i], "slot #{i} should be present"
          assert_in_delta r, got[i], 1e-9, "slot #{i}"
        end
      end
    end

    agree.(grp.sum)              { |m| m.sum }
    agree.(grp.mean)             { |m| m.mean }
    agree.(grp.min)              { |m| m.min }
    agree.(grp.max)              { |m| m.max }
    agree.(grp.variance)         { |m| m.variance }
    agree.(grp.stddev)           { |m| m.stddev }
    agree.(grp.median)           { |m| m.median }
    agree.(grp.percentile(30))   { |m| m.percentile(30) }
    agree.(grp.count_not_masked) { |m| m.count_not_masked }
  end

  # ---- count family + prod (new named surface) ------------------------------

  def test_count_family_and_prod
    keys = %w[b a b c a b]
    val  = CA_INT32([10, 20, 30, 40, 50, 60])
    grp  = val.group_by_category(CA_OBJECT(keys).categorize)   # labels [b,a,c]
    # no-arg count == count_not_masked (Ruby idiom, matches core)
    assert_equal grp.count_not_masked.to_a, grp.count.to_a
    assert_equal [3, 2, 1], grp.count.to_a
    # count(v)
    assert_equal [1, 0, 0], grp.count(10).to_a
    assert_equal [0, 1, 0], grp.count(50).to_a
    # count(UNDEF) == count_masked
    assert_equal grp.count_masked.to_a, grp.count(UNDEF).to_a
    # prod: float64, per-group product; empty -> 1.0 (identity)
    assert_equal CA_FLOAT64, grp.prod.data_type
    assert_in_delta 10 * 30 * 60, grp.prod[0], 1e-9
    assert_in_delta 20 * 50,      grp.prod[1], 1e-9
    assert_in_delta 40,           grp.prod[2], 1e-9
  end

  def test_count_v_skips_masked
    val = CA_INT32([10, 10, 30, 10]); val[1] = UNDEF       # a: 10,_,30 ; b: 10
    cat = CA_OBJECT(%w[a a a b]).categorize(labels: %w[a b])
    grp = val.group_by_category(cat)
    assert_equal [1, 1], grp.count(10).to_a                # masked 10 not counted
  end

  # ---- all / any (boolean value dtype) --------------------------------------

  def test_all_any_boolean
    bval = CA_BOOLEAN([1, 0, 1, 1, 1, 1])                  # b:[1,1,1] a:[0,1] c:[1]
    grp  = bval.group_by_category(CA_OBJECT(%w[b a b c a b]).categorize)
    assert_equal [true, false, true], grp.all.to_a
    assert_equal [true, true, true], grp.any.to_a
    # empty category: all -> true (vacuous), any -> false
    g2 = CA_BOOLEAN([1, 1]).group_by_category(
           CA_OBJECT(%w[a a]).categorize(labels: %w[a b]))
    assert_equal [true, true], g2.all.to_a                       # 'b' empty -> true
    assert_equal [true, false], g2.any.to_a                       # 'b' empty -> false
  end

  # ---- generic iterate: each / reduce (custom-reduction escape hatch) --------

  def test_each_yields_members_and_enumerator
    val = CA_INT32([10, 20, 30, 40, 50, 60])
    grp = val.group_by_category(CA_OBJECT(%w[b a b c a b]).categorize)
    seen = []
    ret  = grp.each { |m| seen << m.to_a }
    assert_same grp, ret
    assert_equal [[10, 30, 60], [20, 50], [40]], seen
    assert_kind_of Enumerator, grp.each                    # no-block -> Enumerator
  end

  def test_reduce_block_and_init_forms
    val = CA_INT32([10, 20, 30, 40, 50, 60])
    grp = val.group_by_category(CA_OBJECT(%w[b a b c a b]).categorize)
    # block form: custom per-group scalar
    assert_equal [50, 30, 0], grp.reduce { |m| m.max - m.min }.to_a
    # init form: fold each group's members
    assert_equal [100, 70, 40], grp.reduce(0) { |acc, x| acc + x }.to_a
    assert_raise(LocalJumpError) { grp.reduce }            # no block
  end

  # ---- tier 2: minmax / variancep / stddevp / min_index / max_index ----------

  def test_tier2_minmax_variancep_position
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                         # labels [b,a,c]
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    grp  = val.group_by_category(cat)
    members = grp.labels.map { |l| val[cat.eq(l)] }
    mn, mx = grp.minmax
    assert_equal members.map { |m| m.min }, mn.to_a
    assert_equal members.map { |m| m.max }, mx.to_a
    grp.labels.each_index do |i|
      assert_in_delta members[i].variancep, grp.variancep[i], 1e-9   # population
      assert_in_delta members[i].stddevp,   grp.stddevp[i],   1e-9
    end
    assert_equal [0, 0, 0], grp.min_index.to_a               # each group's min is first
    assert_equal [2, 1, 0], grp.max_index.to_a               # group-local positions
  end

  def test_tier2_empty_and_singleton
    cat = CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c])  # 'b' singleton, 'c' empty
    grp = CA_DOUBLE([5, 10, 20]).group_by_category(cat)
    assert_in_delta 0.0, grp.variancep[1], 1e-12              # singleton -> pop var 0.0
    [grp.variancep, grp.stddevp, grp.min_index, grp.max_index].each do |r|
      assert_equal true, r.is_masked[2]                          # empty 'c' -> masked
    end
  end

  # ---- weighted: wsum / wmean ------------------------------------------------

  def test_weighted_wsum_wmean
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                         # labels [b,a,c]
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    wts  = CA_DOUBLE([1, 1, 2, 1, 3, 1])
    grp  = val.group_by_category(cat)
    grp.labels.each_index do |i|
      v = val[cat.eq(grp.labels[i])]; w = wts[cat.eq(grp.labels[i])]
      assert_in_delta v.wsum(w),  grp.wsum(wts)[i],  1e-9
      assert_in_delta v.wmean(w), grp.wmean(wts)[i], 1e-9
    end
    assert_equal CA_FLOAT64, grp.wsum(wts).data_type
    assert_raise(ArgumentError) { grp.wsum(CA_DOUBLE([1, 2])) }   # elements mismatch
  end

  def test_weighted_empty_and_masked
    cat = CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c])  # 'c' empty
    v   = CA_DOUBLE([10, 20, 30]); v[0] = UNDEF                # 'a' = [_, 20]
    grp = v.group_by_category(cat)
    w   = CA_DOUBLE([2, 3, 1])
    assert_equal [60.0, 30.0, 0.0], grp.wsum(w).to_a          # a=20*3; b=30; empty c=0
    assert_in_delta 20.0, grp.wmean(w)[0], 1e-9               # 60/3 (masked value skipped)
    assert_equal true, grp.wmean(w).is_masked[2]                 # empty c -> masked
    # a masked weight is skipped too
    cat2 = CA_OBJECT(%w[b a b c a b]).categorize
    g2   = CA_DOUBLE([10, 20, 30, 40, 50, 60]).group_by_category(cat2)
    wm   = CA_DOUBLE([1, 1, 2, 1, 3, 1]); wm[2] = UNDEF
    assert_equal 70.0, g2.wsum(wm)[0]                          # 'b' skips masked weight (30)
  end

  # ---- min_addr / max_addr (flat source address) -----------------------------

  def test_min_max_addr
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                        # labels [b,a,c]
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    grp  = val.group_by_category(cat)
    assert_equal [0, 1, 3], grp.min_addr.to_a               # source positions of the minima
    assert_equal [5, 4, 3], grp.max_addr.to_a
    # the address indexes back into the raveled source
    assert_equal grp.min.to_a, val.reshape(6)[grp.min_addr].to_a
    assert_equal grp.max.to_a, val.reshape(6)[grp.max_addr].to_a
    # empty category -> masked
    g2 = CA_DOUBLE([10, 20, 30]).group_by_category(
           CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c]))
    assert_equal true, g2.min_addr.is_masked[2]
  end

  # ---- sort_addr (flat source addresses, group-major) ------------------------

  def test_sort_addr_round_trip
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                         # labels [b,a,c]
    val  = CA_INT32([10, 30, 60, 40, 50, 20])
    grp  = val.group_by_category(cat)                         # b={10,60,20}, a={30,50}, c={40}
    sa   = grp.sort_addr
    assert_equal grp.elements.sum, sa.elements               # length nvalid
    assert_equal CA_INT64, sa.data_type
    # gathering the source by sort_addr yields values grouped and sorted-within-group
    gathered = val.reshape(6)[sa].to_a
    starts   = [0]; grp.elements.to_a.each { |n| starts << starts[-1] + n }
    grp.labels.each_index do |c|
      seg = gathered[starts[c]...starts[c + 1]]
      assert_equal seg.sort, seg                             # ascending within each group
    end
  end

  def test_sort_addr_min_max_invariant
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize
    val  = CA_DOUBLE([10, 30, 60, 40, 50, 20])
    grp  = val.group_by_category(cat)
    sa     = grp.sort_addr
    starts = [0]; grp.elements.to_a.each { |n| starts << starts[-1] + n }
    grp.labels.each_index do |c|
      # first sorted address is the minimum, last is the maximum (no mask here)
      assert_equal grp.min_addr[c], sa[starts[c]]
      assert_equal grp.max_addr[c], sa[starts[c + 1] - 1]
    end
  end

  def test_sort_addr_masked_value_to_tail
    # a masked value sorts to the tail of its segment (matching CArray#sort)
    keys = %w[a a a b]
    val  = CA_DOUBLE([30, 10, 20, 40]); val[0] = UNDEF        # a = {UNDEF, 10, 20}
    grp  = val.group_by_category(CA_OBJECT(keys).categorize)
    sa   = grp.sort_addr
    # segment for 'a' is [0, 3): present values ascending first, masked address last
    assert_equal [1, 2, 0], sa[0...3].to_a                    # 10@1, 20@2, then masked 30@0
    assert_equal 3, sa[3]                                     # 'b' single member
    # first present address is still the minimum
    assert_equal grp.min_addr[0], sa[0]
  end

  # ---- tier 3: no-arg quantile (five-number summary) -------------------------

  def test_tier3_quantile_five_number
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                         # labels [b,a,c]
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    grp  = val.group_by_category(cat)
    q = grp.quantile
    assert_equal 5, q.size
    members = grp.labels.map { |l| val[cat.eq(l)] }
    grp.labels.each_index do |i|
      ref = members[i].quantile                              # [min, Q1, median, Q3, max]
      5.times { |j| assert_in_delta ref[j], q[j][i], 1e-9 }
    end
    assert_equal grp.min.to_a,    q[0].to_a                  # percentile(0) == min
    assert_equal grp.median.to_a, q[2].to_a
    assert_equal grp.max.to_a,    q[4].to_a                  # percentile(100) == max
  end

  def test_tier3_quantile_empty_masked
    cat = CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c]) # 'c' empty
    q = CA_DOUBLE([5, 10, 20]).group_by_category(cat).quantile
    q.each { |arr| assert_equal true, arr.is_masked[2] }        # empty -> all five masked
  end

  # ---- map: group-wise element-wise transform (new array, source unchanged) --

  def test_map_group_relative_and_broadcast
    val = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    grp = val.group_by_category(CA_OBJECT(%w[b a b c a b]).categorize) # b=33.3 a=35 c=40
    centered = grp.map { |m| m - m.mean }
    assert_equal [6], centered.shape
    assert_in_delta(-23.333, centered[0], 1e-3)
    assert_in_delta 15.0,    centered[4], 1e-3
    assert_equal [10.0, 20.0, 30.0, 40.0, 50.0, 60.0], val.to_a         # source unchanged
    # scalar return broadcasts over the group's cells
    gm = grp.map { |m| m.mean }
    assert_in_delta 33.333, gm[0], 1e-3
    assert_in_delta 35.0,   gm[1], 1e-3
  end

  def test_map_excluded_cells_masked
    cat = CA_OBJECT(%w[x y x q y x]).categorize(labels: %w[x y])        # 'q' excluded
    out = CA_DOUBLE([1, 2, 3, 4, 5, 6]).group_by_category(cat).map { |m| m * 0 + 1 }
    assert_equal true, out.is_masked[3]                                    # excluded -> UNDEF
    assert_equal false, out.is_masked[0]
  end

  def test_map_nd_preserves_shape_and_needs_block
    vnd = CA_DOUBLE([[10, 20], [30, 40]])
    gnd = vnd.group_by_category(CA_OBJECT([%w[a b], %w[b a]]).categorize) # a,b means 25
    r   = gnd.map { |m| m - m.mean }
    assert_equal [2, 2], r.shape
    assert_equal [[-15.0, -5.0], [5.0, 15.0]], r.to_a
    assert_raise(LocalJumpError) { gnd.map }                            # no block
  end

  # ---- Enumerable is not mixed in (no reduction-name leak) -------------------

  def test_no_enumerable_leak
    grp = CA_INT32([1, 2, 3]).group_by_category(CA_OBJECT(%w[a b a]).categorize)
    assert_equal false, CAIterator.include?(Enumerable)
    assert_raise(NoMethodError) { grp.to_a }               # no Enumerable#to_a
  end
end
