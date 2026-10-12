require "test/unit"
require "carray"

# A reduction reached through another layer (an iterator, a Face, the
# three-valued boolean fold, the object escape of the weighted reductions)
# takes the same keywords as the core reduction and gives them the same
# meaning.
class TestReduceKeywordForwarding < Test::Unit::TestCase

  def setup
    @f = CArray.float64(3, 4).seq!
    @f[0, 0] = UNDEF
    @f[1, 1] = UNDEF
    @b = @f > 3
  end

  # ---- all / any / none with skip_masked: false

  def test_kleene_fold_checks_keywords_as_the_core_does
    assert_raise(ArgumentError) { @b.all(axis: 0, skip_masked: false, min_count: 100) }
    assert_raise(ArgumentError) { @b.all(skip_masked: false, zzz: 1) }
    assert_raise(CArray::DataTypeError) { @f.all(skip_masked: false) }
    e = assert_raise(ArgumentError) { @b.none(axis: 5, skip_masked: false) }
    assert_match(/\Anone:/, e.message)
  end

  def test_kleene_fold_keeps_axes_and_folds_every_axis
    r = @b.any(keep_axis: true, skip_masked: false)
    assert_equal [1, 1], r.shape
    assert_equal true, r[0, 0]
    assert_equal true, @b.any(axis: [0, 1], skip_masked: false)
  end

  def test_kleene_fold_values
    # column 0 is [UNDEF, true, true]: no known false, so all is undetermined
    assert_equal [UNDEF, false, false, false], @b.all(axis: 0, skip_masked: false).to_a
    # row 0 is [UNDEF, false, false, false]: no known true, so any is undetermined
    assert_equal [UNDEF, true, true], @b.any(axis: 1, skip_masked: false).to_a
    assert_equal [UNDEF, false, false], @b.none(axis: 1, skip_masked: false).to_a
    assert_equal false, @b.all(skip_masked: false)
    assert_equal true, @b.any(skip_masked: false)
  end

  # ---- object wsum / wmean

  def test_object_weighted_reductions_check_keywords
    o = CA_OBJECT([1, 2, 3])
    w = CA_OBJECT([1, 1, 2])
    assert_raise(ArgumentError) { o.wmean(w, zzz: 1) }
    assert_raise(ArgumentError) { o.wsum(w, zzz: 1) }
    e = assert_raise(ArgumentError) { o.wsum(w, axis: 5) }
    assert_match(/\Awsum:/, e.message)
    e = assert_raise(ArgumentError) { o.wmean(w, min_count: -1) }
    assert_match(/\Awmean:/, e.message)
    assert_equal 0, o.wmean(w, min_count: 9, fill_value: 0)
  end

  # ---- all / any take no min_count: on any path

  def test_all_and_any_refuse_min_count_everywhere
    assert_raise(ArgumentError) { @b.all(min_count: 2) }
    assert_raise(ArgumentError) { @b.windows(-1..1, -1..1).all(min_count: 4) }
    assert_raise(ArgumentError) { @b.blocks(1, 2).any(min_count: 1) }
    assert_raise(ArgumentError) { @b[nil, :>].all(min_count: 1) }
    h = CArray.boolean(4, 1) { 1 }
    g = h[h.axis_group(CA_INT32([0, 0, 1, 1]).categorize, nil)]
    assert_raise(ArgumentError) { g.all(axis: :group, min_count: 2) }
    assert_raise(ArgumentError) { @b.windows(-1..1, -1..1).all(axis: 0) }
  end

  # ---- slab iterator reductions take min_count: / fill_value:

  def test_slab_reductions_take_reduction_keywords
    s = @f[nil, :>]
    assert_equal @f.sum(axis: 1, min_count: 4).to_a, s.sum(min_count: 4).to_a
    assert_equal [-1.0, -1.0, 9.5], s.mean(min_count: 4, fill_value: -1).to_a
    assert_equal [-1.0, -1.0, 9.5], s.median(min_count: 4, fill_value: -1).to_a
    assert_raise(ArgumentError) { s.sum(zzz: 1) }
  end

  # ---- a Face's fill_value: is a value of the Face

  def test_time_fill_value_is_a_time
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"],
                    unit: :D).reshape(2, 2)
    t[1, 1] = UNDEF
    e = t[0, 0]
    assert_equal e, t.min(min_count: 100, fill_value: e)
    assert_equal e, t.mean(min_count: 100, fill_value: e)
    assert_equal [t[0, 0], e], t.min(axis: 1, min_count: 2, fill_value: e).to_a
    assert_equal [t[0, 1], e], t.max(axis: 1, min_count: 2, fill_value: e).to_a
    assert_equal e, t.mean(axis: 1, min_count: 2, fill_value: e)[1]
    assert_equal [2, 1], t.median(axis: 1, keep_axis: true, min_count: 2, fill_value: e).shape
    assert_equal [e, e], t.percentile(10, 90, min_count: 100, fill_value: e)
    assert_equal e, t.blocks(2, 2).mean(min_count: 4, fill_value: e)[0, 0]
    assert_equal [2], t.mean(axis: 1, min_count: 2).shape
  end

  def test_timedelta_fill_value_is_a_duration
    d = CA_INT64([[1, 2], [3, 4]]).timedelta(unit: :D)
    d[1, 1] = UNDEF
    e = d[0, 1]
    assert_equal e, d.min(min_count: 100, fill_value: e)
    assert_equal e, d.accumulate(min_count: 100, fill_value: e)
    assert_equal [d[0, 0] + d[0, 1], e], d.sum(axis: 1, min_count: 2, fill_value: e).to_a
  end

  # ---- categorical axis: variance answers in the core's type

  def test_categorical_axis_variance_keeps_the_core_type
    ob = CA_OBJECT([[1/3r, 2/3r, 1/7r, 1], [1, 2, 3, 4]])
    c  = CA_INT32([0, 0, 1, 1]).categorize
    [:variance, :variancep, :stddev, :stddevp].each do |op|
      r = ob.group_by_category(c).send(op, axis: 1)
      assert_equal ob[nil, 0..1].send(op, axis: 1).data_type, r.data_type, op.to_s
    end
    assert_equal [[1/18r, 1], [18/49r, 1]],
                 ob.group_by_category(c).variance(axis: 1).to_a
  end

end
