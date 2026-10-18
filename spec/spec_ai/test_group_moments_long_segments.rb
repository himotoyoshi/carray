require "test/unit"
require "carray"

# The per-group count / sum / min / max of a long group (64 cells or more,
# without masked cells) are read in several lanes and merged. Each group's
# answer is the one the core gives for that group's cells.
class TestGroupMomentsLongSegments < Test::Unit::TestCase

  def same (a, b)
    if a.is_a?(Float) && a.nan?
      b.is_a?(Float) && b.nan?
    else
      a == b
    end
  end

  def check (v, codes)
    it = v.group_by_category(CACategorical.send(:from_keys, [CA_INT64(codes)]))
    labels = CACategorical.send(:from_keys, [CA_INT64(codes)]).labels
    sums, mins, maxs = it.sum, it.min, it.max
    labels.each_with_index do |lab, c|
      cells = v[CA_BOOLEAN(codes.map { |x| x == lab })]
      assert same(mins[c], cells.min), "min of group #{lab}"
      assert same(maxs[c], cells.max), "max of group #{lab}"
      ref = cells.sum
      if ref.is_a?(Float) && ref.nan?
        assert sums[c].nan?, "sum of group #{lab}"
      else
        assert_in_delta ref, sums[c], 1e-9 * [1, ref.abs].max, "sum of group #{lab}"
      end
    end
  end

  def test_nan_in_each_lane_of_a_long_group
    [:float32, :float64].each do |dt|
      (0...8).each do |lane|
        n = 64 + 3                                  # 8 full rounds and a tail
        vals = Array.new(n) { |i| (i * 7 % 13) - 6.0 }
        (lane...n).step(8) { |i| vals[i] = Float::NAN }
        check(CArray.new(dt, [n]).tap { |a| a[] = vals }, [0] * n)
      end
    end
  end

  def test_extremum_in_one_lane_only
    n = 80
    (0...8).each do |lane|
      vals = Array.new(n) { 1.0 }
      vals[lane + 8] = -5.0
      vals[lane + 16] = 9.0
      check(CA_FLOAT64(vals), [0] * n)
    end
  end

  def test_long_group_of_only_nan
    n = 70
    v = CA_FLOAT64([Float::NAN] * n)
    it = v.group_by_category(CACategorical.send(:from_keys, [CA_INT64([0] * n)]))
    assert it.min[0].nan?
    assert it.max[0].nan?
    assert it.sum[0].nan?
  end

  def test_long_groups_of_every_numeric_type
    srand 11
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64 float32 float64].each do |dt|
      n = 1000
      codes = Array.new(n) { rand(4) }
      vals  = Array.new(n) { dt.to_s.start_with?("u") ? rand(100) : rand(-100..100) }
      check(CArray.new(dt, [n]).tap { |a| a[] = vals }, codes)
    end
  end
end
