require "test/unit"
require "carray"

# A reduction of a segment or categorical iterator, and of a GroupedFrame
# (group_by / resample), takes min_count: and fill_value: as a core
# reduction does: each group answers what the core reduction answers for
# the group's values alone.

class TestGroupReductionMinCount < Test::Unit::TestCase

  OPS = %i[sum accumulate max min mean median variance stddev variancep stddevp prod]

  def setup
    CAFrame  # load the frame
    rng = Random.new(7)
    @v = CA_FLOAT64(Array.new(40) { rng.rand(10).to_f })
    Array.new(40) { |i| i }.select { rng.rand < 0.3 }.each { |i| @v[i] = UNDEF }
    @codes = CA_INT32(Array.new(40) { rng.rand(6) })
    @cat = @codes.categorize
  end

  def group_values(c)
    @v[@codes.eq(@cat.labels[c])].copy
  end

  def answer(x)
    x = x.to_a if x.is_a?(CArray)
    x.is_a?(Float) && x.nan? ? :nan : x
  end

  def test_each_group_answers_as_the_core_reduction
    g = @v.group_by_category(@cat)
    OPS.each do |op|
      [0, 1, 3, 6].each do |k|
        [nil, -1.0].each do |fill|
          kw = { min_count: k }
          kw[:fill_value] = fill unless fill.nil?
          got = g.public_send(op, **kw)
          @cat.labels.size.times do |c|
            want = group_values(c).public_send(op, **kw)
            assert_equal answer(want), answer(got[c]), "#{op} #{kw} group #{c}"
          end
        end
      end
    end
  end

  def test_percentile_and_minmax
    g = @v.group_by_category(@cat)
    @cat.labels.size.times do |c|
      vals = group_values(c)
      assert_equal answer(vals.percentile(50, min_count: 4)), answer(g.percentile(50, min_count: 4)[c])
      lo, hi = g.minmax(min_count: 4, fill_value: -1.0)
      assert_equal vals.minmax(min_count: 4, fill_value: -1.0).map { |x| answer(x) },
                   [answer(lo[c]), answer(hi[c])]
    end
  end

  def test_segments_and_the_axis_form
    s = CA_FLOAT64([1, 2, 3, 4, 5])
    s[1] = UNDEF                                             # 2 present values in each segment
    assert_equal [UNDEF, UNDEF], s.segments(lengths: [3, 2]).mean(min_count: 3).to_a
    assert_equal [2.0, 4.5], s.segments(lengths: [3, 2]).mean(min_count: 2).to_a
    h = CA_FLOAT64([[1, 2], [3, 4], [5, 6]])
    h[0, 0] = UNDEF
    gh = h.group_by_category(CA_INT32([0, 0, 1]).categorize)
    assert_equal [[UNDEF, 3.0], [UNDEF, UNDEF]], gh.mean(axis: 0, min_count: 2).to_a
  end

  def test_keywords_are_checked
    g = @v.group_by_category(@cat)
    assert_raise(TypeError)     { g.mean(min_count: 1.5) }
    assert_raise(ArgumentError) { g.mean(min_count: -1) }
    assert_raise(ArgumentError) { g.mean(foo: 1) }
    assert_raise(ArgumentError) { g.quantile(min_count: 1) }   # as CArray#quantile
  end

  def test_resample_takes_min_count
    t = CArray.time_range("2024-12-01 00:00", "2024-12-01 02:00", unit: :m, step: "10 minutes")
    df = CAFrame.new({ "time" => t, "temp" => CA_FLOAT64((0...t.elements).map(&:to_f)) })
    df["temp"][9] = UNDEF                                    # 01:30
    g = df.resample("time", "1 hour", label: :right)
    assert_equal [UNDEF, 3.5, UNDEF], g.mean(min_count: 6)["temp"].to_a
    assert_equal [-99.0, 3.5, 9.6], g.mean(min_count: 5, fill_value: -99.0)["temp"].to_a
    r = g.aggregate("n" => ["temp", :count], "t" => ["temp", :mean, min_count: 6])
    assert_equal [1, 6, 5], r["n"].to_a
    assert_equal [UNDEF, 3.5, UNDEF], r["t"].to_a
    assert_raise(ArgumentError) { g.aggregate("x" => ["temp", ->(s) { s.sum }, min_count: 1]) }
    assert_raise(ArgumentError) { g.mean(foo: 1) }
  end

end
