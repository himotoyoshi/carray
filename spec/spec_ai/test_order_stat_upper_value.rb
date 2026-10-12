require "test/unit"
require "carray"

# The upper of the two cells an order statistic interpolates between is the
# next value in sort order, also when that value is +Infinity or NaN (NaN
# sorts after every number).  Every path -- one partition, a full sort, a
# masked fiber -- answers the same.
class TestOrderStatUpperValue < Test::Unit::TestCase

  INF = Float::INFINITY
  NAN = Float::NAN

  def assert_same_value (expect, got, msg = nil)
    if expect.nan?
      assert got.nan?, "#{msg}: expected NaN, got #{got}"
    else
      assert_equal expect, got, msg
    end
  end

  # median, percentile(75), and the reference read from sort
  CASES = {
    "two with infinity"   => [[1.0, INF],            INF, INF],
    "four with infinity"  => [[1.0, INF, INF, 2.0],  INF, INF],
    "two with nan"        => [[NAN, -1.0],           NAN, NAN],
    "three with nan"      => [[NAN, -1.0, 5.0],      5.0, NAN],
    "nan in upper half"   => [[1.0, NAN, 2.0, 3.0],  2.5, NAN],
  }

  %i[float64 float32].each do |dt|
    CASES.each do |name, (vals, med, p75)|
      define_method("test_#{dt}_#{name.tr(' ', '_')}") do
        a = CArray.new(dt, [vals.size]); a[] = CA_FLOAT64(vals)
        assert_same_value med, a.median, "median"
        assert_same_value p75, a.percentile(75), "percentile(75)"
        assert_same_value p75, a.percentile(25, 75)[1], "percentile(25, 75)"
        assert_same_value med, a.quantile[2], "quantile"
        row = a.reshape(1, vals.size)
        assert_same_value med, row.median(axis: 1)[0], "median(axis:)"
        assert_same_value p75, row.percentile(75, axis: 1)[0], "percentile(axis:)"
        m = CArray.new(dt, [1, vals.size + 1]); m[0, 1..-1] = a; m[0, 0] = UNDEF
        assert_same_value med, m.median, "masked median"
        assert_same_value med, m.median(axis: 1)[0], "masked median(axis:)"
      end
    end
  end
end
