require "test/unit"
require "carray"

# Reductions over CAShift / CAWindow take two walks that skip the cell-by-cell
# gather: a row whose innermost axis is shifted is gathered as one run of
# in-range cells plus its out-of-range head and tail, and a fiber that leaves
# out the innermost axis is read from one row-major copy of the whole view.
# Each answer must equal the same reduction over view.copy.
class TestShiftReductionPaths < Test::Unit::TestCase

  SHIFTS = [-7, -2, -1, 0, 1, 3, 7]

  def views (a, sh)
    ranges = sh.zip(a.shape).map { |s, n| (-s)..(n - 1 - s) }
    {
      "shift"        => a.shift(*sh),
      "shift UNDEF"  => a.shift(*sh, fill_value: UNDEF),
      "win nearest"  => a.window(*ranges, bounds: "nearest"),
      "win fill 9"   => a.window(*ranges, fill_value: 9),
    }
  end

  def check (a, sh)
    views(a, sh).each do |name, v|
      ref = v.copy
      where = "#{name} #{sh.inspect} masked=#{a.has_mask?}"
      assert_equal ref.sum, v.sum, "sum #{where}"
      assert_equal ref.min, v.min, "min #{where}"
      a.ndim.times do |k|
        assert_equal ref.sum(axis: k).to_a, v.sum(axis: k).to_a,
                     "sum(axis: #{k}) #{where}"
      end
    end
  end

  def test_2d
    SHIFTS.product(SHIFTS).each do |sh|
      check(CArray.int64(5, 6).seq, sh)
    end
  end

  def test_2d_masked
    a = CArray.int64(5, 6).seq
    a[2, 3] = UNDEF
    SHIFTS.product(SHIFTS).each { |sh| check(a, sh) }
  end

  def test_3d
    a = CArray.float64(3, 4, 5).seq
    SHIFTS.product([-1, 0, 2], SHIFTS).each { |sh| check(a, sh) }
  end

  def test_shifted_rows_write_back
    a = CArray.int32(4, 5).seq
    v = a.shift(0, 2)
    v[] = CArray.int32(4, 5).seq.add!(100)
    # view cell j is parent cell j - 2: parent 0..2 take 102..104, 3..4 keep
    assert_equal [102, 103, 104, 3, 4], a[0, nil].to_a
  end
end
