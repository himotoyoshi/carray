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
    # Every reduction answers in the type the core promotes the value to.
    assert_equal CA_FLOAT64, grp.sum.data_type          # core sum promotes
    assert_equal CA_INT32,   grp.accumulate.data_type   # the in-type fold
    assert_equal CA_FLOAT64, grp.prod.data_type
    assert_equal CA_INT32,   grp.max.data_type          # core min / max keep it
    assert_equal CA_INT32,   grp.min.data_type
    assert_equal CA_FLOAT64, grp.mean.data_type
    assert_equal CA_FLOAT64, grp.median.data_type
    assert_equal CA_FLOAT64, grp.stddev.data_type
    assert_equal CA_FLOAT64, grp.variance.data_type
  end

  # The per-category answer is the core reduction lifted to the category, so its
  # data type is whatever `CArray#<op>` promotes that value type to -- including
  # the payloads that have no per-category fast path (boolean / complex /
  # object) and once answered in a type of their own.
  def test_reduction_output_dtype_follows_the_core
    cat = CA_INT32([0, 0, 1, 1]).categorize
    {
      CA_BOOLEAN([1, 1, 0, 1])  => { sum: CA_UINT64,   accumulate: CA_BOOLEAN,
                                     prod: CA_UINT64,  min: CA_UINT64,  max: CA_UINT64,
                                     mean: CA_FLOAT64, variance: CA_FLOAT64,
                                     stddev: CA_FLOAT64 },
      CA_INT32([1, 2, 3, 4])    => { sum: CA_FLOAT64,  accumulate: CA_INT32,
                                     prod: CA_FLOAT64, min: CA_INT32,   max: CA_INT32,
                                     mean: CA_FLOAT64, variance: CA_FLOAT64,
                                     stddev: CA_FLOAT64 },
      CA_CMPLX128([1, 2, 3, 4]) => { sum: CA_CMPLX128, accumulate: CA_CMPLX128,
                                     prod: CA_CMPLX128, mean: CA_CMPLX128,
                                     variance: CA_FLOAT64 },
      CA_OBJECT([1, 2, 3, 4])   => { sum: CA_OBJECT,   accumulate: CA_OBJECT,
                                     prod: CA_OBJECT,  min: CA_OBJECT,  max: CA_OBJECT,
                                     mean: CA_OBJECT,  variance: CA_OBJECT,
                                     variancep: CA_OBJECT, stddev: CA_FLOAT64,
                                     median: CA_OBJECT },
    }.each do |value, expected|
      grp = value.group_by_category(cat)
      expected.each do |op, dtype|
        assert_equal dtype, grp.public_send(op).data_type,
                     "#{value.data_type} #{op}"
        assert_equal value.reshape(1, value.elements).public_send(op, axis: 1).data_type,
                     grp.public_send(op).data_type,
                     "#{value.data_type} #{op} drifts from CArray##{op}"
      end
    end
  end

  # An object payload folds exactly (no float64 round trip), and a wide integer
  # keeps every bit under `accumulate` where `sum` folds in float64.
  def test_reduction_values_survive_the_promotion
    cat = CA_INT32([0, 0, 1, 1]).categorize
    assert_equal [Rational(3, 2), Rational(7, 2)],
                 CA_OBJECT([Rational(1,2), Rational(1,1),
                            Rational(3,2), Rational(2,1)]).group_by_category(cat).sum.to_a
    big = 1 << 60
    grp = CA_INT64([big, 1, big, 1]).group_by_category(cat)
    assert_equal [big + 1, big + 1], grp.accumulate.to_a
    assert_equal [2, 3],             CA_BOOLEAN([1, 1, 0, 1, 1, 1]).
                                       group_by_category(CA_INT32([0,0,0,1,1,1]).categorize).sum.to_a

    # Ratios stay exact for an object payload, and a complex one has a mean.
    thirds = CA_OBJECT([Rational(1,3), Rational(2,3), Rational(1,4), Rational(3,4)])
    assert_equal [Rational(1,2), Rational(1,2)], thirds.group_by_category(cat).mean.to_a
    assert_equal [Complex(2,2), Complex(1,1)],
                 CA_CMPLX128([Complex(1,1), Complex(3,3),
                              Complex(0,2), Complex(2,0)]).group_by_category(cat).mean.to_a
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

  # ---- NaN ---------------------------------------------------------------
  #
  # The contract above -- a group result equals CArray#<reduction> over the
  # group's members -- has to hold when a member is NaN. It did not: the
  # extremum kernels seeded the accumulator with the first present cell and
  # then compared, so a NaN seed was never displaced (every comparison against
  # it is false) and the answer depended on where in the segment the NaN sat.
  # A reduction that is order-free stopped being order-free.

  NAN = 0.0 / 0.0

  def assert_same_float(expected, actual, what)
    if expected.is_a?(Float) && expected.nan?
      assert_true(actual.is_a?(Float) && actual.nan?, "#{what}: want NaN, got #{actual.inspect}")
    else
      assert_equal(expected, actual, what)
    end
  end

  def test_a_nan_loses_every_contest_and_the_answer_does_not_move_with_it
    [[NAN, 1.0, 5.0], [1.0, NAN, 5.0], [1.0, 5.0, NAN]].each do |vals|
      grp = CA_DOUBLE(vals).group_by_category(CA_INT32([0, 0, 0]).categorize)
      ref = CA_DOUBLE(vals)
      assert_same_float(ref.min, grp.min[0], "min #{vals.inspect}")
      assert_same_float(ref.max, grp.max[0], "max #{vals.inspect}")
      assert_equal(ref.min_index, grp.min_index[0], "min_index #{vals.inspect}")
      assert_same_float(ref.median, grp.median[0], "median #{vals.inspect}")
    end
  end

  def test_a_group_of_nothing_but_nan
    grp = CA_DOUBLE([NAN, NAN]).group_by_category(CA_INT32([0, 0]).categorize)
    # the extremum is that NaN, as in the core; the position of it is UNDEF,
    # the same answer the core gives for a group with no present cell at all
    assert_true(grp.min[0].nan?)
    assert_true(grp.max[0].nan?)
    assert_true(grp.min_index.is_masked[0])
    assert_true(grp.max_index.is_masked[0])
  end

  def test_an_order_statistic_puts_nan_last_and_clamps_its_neighbour
    # NaN sorts last, so a position is picked out of [numbers..., NaN...];
    # a position whose upper neighbour would be a NaN interpolates against
    # itself rather than producing NaN
    g2 = CA_DOUBLE([NAN, -9.0]).group_by_category(CA_INT32([0, 0]).categorize)
    assert_equal(-9.0, g2.median[0])
    assert_equal(-9.0, g2.percentile(75)[0])
    g4 = CA_DOUBLE([NAN, 1.0, 7.0, -8.0]).group_by_category(CA_INT32([0] * 4).categorize)
    assert_equal(4.0, g4.median[0])
    assert_equal(7.0, g4.percentile(75)[0])
  end

  def test_nan_answers_match_the_core_across_shapes_and_data_types
    # the strongest form of the contract: sweep random NaN patterns and check
    # every member against CArray's own reduction over the same cells
    srand(12345)
    [CA_FLOAT64, CA_FLOAT32].each do |dt|
      120.times do
        n = 1 + rand(9)
        k = 1 + rand(3)
        vals  = Array.new(n) { rand < 0.35 ? NAN : (rand(20) - 10).to_f }
        codes = Array.new(n) { rand(k) }
        h = CArray.new(dt, [n]); h[] = CA_DOUBLE(vals)
        grp = h.group_by_category(CA_INT32(codes).categorize(labels: (0...k).to_a))
        got = { min: grp.min, max: grp.max, min_index: grp.min_index,
                median: grp.median, p25: grp.percentile(25) }
        (0...k).each do |c|
          members = (0...n).select { |i| codes[i] == c }
          next if members.empty?
          ref = CArray.new(dt, [members.size])
          ref[] = CA_DOUBLE(members.map { |i| vals[i] })
          what = "#{CArray.data_type_name(dt)} #{members.map { |i| vals[i] }.inspect}"
          assert_same_float(ref.min,       got[:min][c],       "min #{what}")
          assert_same_float(ref.max,       got[:max][c],       "max #{what}")
          assert_equal(ref.min_index,      got[:min_index][c], "min_index #{what}")
          assert_same_float(ref.median,    got[:median][c],    "median #{what}")
          assert_same_float(ref.percentile(25), got[:p25][c],  "p25 #{what}")
        end
      end
    end
  end

  def test_the_axis_form_handles_nan_like_the_flat_one
    rows  = [[NAN, 2.0], [1.0, NAN], [5.0, NAN], [NAN, NAN]]
    codes = [0, 0, 1, 1]
    grp = CA_DOUBLE(rows).group_by_category(CA_INT32(codes).categorize)
    mn, mx = grp.min(axis: 0), grp.max(axis: 0)
    2.times do |c|
      2.times do |j|
        members = (0...rows.size).select { |r| codes[r] == c }
        ref = CA_DOUBLE(members.map { |r| rows[r][j] })
        assert_same_float(ref.min, mn[c, j], "min at [#{c}, #{j}]")
        assert_same_float(ref.max, mx[c, j], "max at [#{c}, #{j}]")
      end
    end
    # the all-NaN cell is the one the seeding defect used to get wrong
    assert_true(mx[1, 1].nan?)
  end

  # ---- a result is the caller's, not the iterator's ------------------------
  #
  # Several members are memoised: one fused kernel fills count / sum / min /
  # max and every consumer reads off it. They handed back the memo itself, so
  # writing into a result changed what the iterator answered from then on --
  # permanently, and for every other member sharing that memo. #sum already
  # copied; the rest did not.

  FLAT_MEMBERS = [:sum, :min, :max, :count, :count_not_masked, :count_masked,
                  :elements, :mean, :prod, :variance, :stddev, :median,
                  :min_index, :max_index].freeze

  def test_no_member_hands_back_the_memo_itself
    grp = CA_DOUBLE([1.0, 2.0, 3.0, 4.0]).group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    FLAT_MEMBERS.each do |op|
      a = grp.public_send(op)
      next unless a.is_a?(CArray)
      assert_not_same(a, grp.public_send(op), "#{op} hands out the same array twice")
    end
    lo1, hi1 = grp.minmax
    lo2, hi2 = grp.minmax
    assert_not_same(lo1, lo2, "minmax lower")
    assert_not_same(hi1, hi2, "minmax upper")
  end

  def test_no_axis_member_hands_back_the_memo_itself
    h = CA_DOUBLE([[1, 2], [3, 4], [5, 6], [7, 8]])
    grp = h.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    [:sum, :min, :max, :count, :count_not_masked, :mean, :prod, :variance].each do |op|
      a = grp.public_send(op, axis: 0)
      assert_not_same(a, grp.public_send(op, axis: 0),
                      "#{op}(axis:) hands out the same array twice")
    end
  end

  def test_writing_into_a_result_does_not_change_the_iterator
    grp = CA_DOUBLE([1.0, 2.0, 3.0, 4.0]).group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    before = { max: grp.max.to_a, minmax: grp.minmax.map(&:to_a),
               count: grp.count.to_a, elements: grp.elements.to_a }

    grp.max[0]      = 999.0
    grp.count[0]    = 77
    grp.elements[0] = 42

    assert_equal(before[:max],      grp.max.to_a)
    assert_equal(before[:minmax],   grp.minmax.map(&:to_a))   # shares the memo
    assert_equal(before[:count],    grp.count.to_a)
    assert_equal(before[:elements], grp.elements.to_a)
  end

  # ---- an iterator that answers only the per-fiber form ---------------------
  #
  # When the classifier does not line up cell-for-cell with the value, there is
  # no grouped copy to reduce, and only the axis: form can work. That was left
  # implicit -- the ivar simply stayed nil -- so a no-axis reduction surfaced
  # whatever NoMethodError the nil reached first, #elements answered nil, and
  # #inspect printed an empty grouping that does not exist. accumulate(axis:)
  # was collateral: it is the one axis: member that asks the core what type it
  # folds into, and the probe was built from the missing buffer.

  def deferred_iterator
    CA_INT32([[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]])
      .group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
  end

  def test_a_no_axis_reduction_names_the_mismatch
    grp = deferred_iterator
    [:sum, :mean, :median, :prod, :count, :elements].each do |op|
      e = assert_raise(ArgumentError, "#{op} should name the mismatch") {
        grp.public_send(op)
      }
      assert_match(/value\.elements \(12\) != cat\.elements \(4\)/, e.message, op.to_s)
      assert_match(/per-fiber/, e.message, op.to_s)
    end
  end

  def test_inspect_says_so_instead_of_showing_an_empty_grouping
    # inspect is what you reach for when something is already puzzling, so it
    # neither raises nor claims a grouping that classified nothing
    assert_match(/per-fiber only/, deferred_iterator.inspect)
    ordinary = CA_INT32([1, 2, 3, 4]).group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    assert_match(/elements=\[2, 2\]/, ordinary.inspect)
  end

  def test_accumulate_along_an_axis_works_without_a_grouped_copy
    assert_equal([[5, 7, 9], [17, 19, 21]], deferred_iterator.accumulate(axis: 0).to_a)
  end

  def test_accumulate_along_an_axis_keeps_the_value_data_type
    grp = deferred_iterator
    assert_equal(CA_INT32, grp.accumulate(axis: 0).data_type)
  end

  # ---- a payload that carries a Face ---------------------------------------
  #
  # The contract is that a group's answer equals the core's reduction over the
  # group's members, and for a Face the core answers in that Face -- CATime#min
  # is a CATime::Element. The output was built from the answer's data type
  # alone, which a fixlen surface has no width from, so what came back was
  # `rb_ca_new_reduced: bytes=0 invalid for data_type=0`: an internal message
  # naming nothing the caller could act on, for members the core handles fine.

  def time_group
    t = CArray.time(["2020-01-03", "2020-01-01", "2020-01-05", "2020-01-02"], unit: :D)
    [t, t.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)]
  end

  def test_a_face_payload_answers_in_its_own_face
    t, grp = time_group
    [:min, :max, :median].each do |op|
      got = grp.public_send(op)
      assert_kind_of(CATime, got, "#{op} comes back as the Face")
      assert_equal(t[0..1].public_send(op), got[0], "#{op} group 0")
      assert_equal(t[2..3].public_send(op), got[1], "#{op} group 1")
    end
  end

  def test_a_payload_independent_member_stays_plain_for_a_face
    _t, grp = time_group
    assert_equal([2, 2], grp.count.to_a)
    assert_equal(CA_INT64, grp.count.data_type)
  end

  def test_a_member_the_core_refuses_for_a_face_still_refuses_in_its_words
    _t, grp = time_group
    e = assert_raise(TypeError) { grp.sum }
    assert_match(/CATime/, e.message)          # the core's own refusal
    assert_not_match(/rb_ca_new_reduced/, e.message)
  end

  # ---- the no-axis surface is one snapshot ---------------------------------
  #
  # Every no-axis reduction works from the category-major copy taken when the
  # iterator was built. The scans read the value array instead, so a write
  # through the source between two calls was visible to a cumsum and not to a
  # sum, off the same iterator. (The axis: form is live throughout, which is
  # its own contract.)

  SNAPSHOT_MEMBERS = [:sum, :mean, :min, :max, :median, :count, :elements,
                      :cumsum, :cumprod, :cummax, :cummin, :cumcount].freeze

  def test_a_write_through_the_source_reaches_no_member
    h = CA_DOUBLE([1.0, 2.0, 3.0, 4.0])
    grp = h.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    before = SNAPSHOT_MEMBERS.to_h { |op| [op, grp.public_send(op).to_a] }

    h[0] = 100.0

    SNAPSHOT_MEMBERS.each do |op|
      assert_equal(before[op], grp.public_send(op).to_a,
                   "#{op} moved with a write through the source")
    end
  end

  def test_a_fresh_iterator_sees_the_write
    h = CA_DOUBLE([1.0, 2.0, 3.0, 4.0])
    cat = CA_INT32([0, 0, 1, 1]).categorize
    h.group_by_category(cat).cumsum        # take the old snapshot
    h[0] = 100.0
    assert_equal([100.0, 102.0, 3.0, 7.0], h.group_by_category(cat).cumsum.to_a)
    assert_equal([102.0, 7.0], h.group_by_category(cat).sum.to_a)
  end

  def test_the_scan_snapshot_carries_masks_and_exclusions
    # it is rebuilt from the permutation and the grouped copy rather than
    # copied again, so this pins that the rebuild is faithful
    h = CA_DOUBLE([1, 2, 3, 4, 5, 6])
    h[2] = UNDEF                                        # masked, still classified
    codes = CArray.uint8(6) { |i| [0, 0, 0, 1, 1, 255][i] }   # cell 5 excluded
    grp = h.group_by_category(CACategorical.from_codes(codes, %w[a b]))

    assert_equal([1.0, 3.0, 3.0, 4.0, 9.0, UNDEF], grp.cumsum.to_a)
    # the masked cell is classified, so the running count holds rather than
    # breaking; only the excluded cell has no group to run in
    assert_equal([1, 2, 2, 1, 2, UNDEF], grp.cumcount.to_a)
    assert_equal([3.0, 9.0], grp.sum.to_a)
  end

  def test_no_enumerable_leak
    grp = CA_INT32([1, 2, 3]).group_by_category(CA_OBJECT(%w[a b a]).categorize)
    assert_equal false, CAIterator.include?(Enumerable)
    assert_raise(NoMethodError) { grp.to_a }               # no Enumerable#to_a
  end
end
