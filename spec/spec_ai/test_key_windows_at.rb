require "test/unit"
require "carray"

# windows(on:, at:): the key windows placed at given points instead of at the
# rows, one answer per point.  A grid of points gives windows on a grid.
class TestKeyWindowsAt < Test::Unit::TestCase
  # The answer of each point found the slow way: the rows whose key lies in
  # the point's window, reduced.
  def reference (key, value, points, before:, after:, exclude:)
    keys = key.to_a
    vals = value.to_a
    points.to_a.map do |t|
      next nil if t.equal?(UNDEF) || (t.is_a?(Float) && !t.finite?)
      lo, hi = t - before, t + after
      rows = keys.each_index.select do |i|
        k = keys[i]
        next false if k.equal?(UNDEF)
        above = %i[lower both].include?(exclude) ? k > lo : k >= lo
        below = %i[upper both].include?(exclude) ? k < hi : k <= hi
        above && below
      end
      rows.map { |i| vals[i] }.reject { |v| v.equal?(UNDEF) }
    end
  end

  def test_answers_match_the_slow_reference
    rng = Random.new(7)
    key = CA_INT64(Array.new(60) { rng.rand(100) })
    key[[5, 17]] = UNDEF
    value = CA_FLOAT64(Array.new(60) { rng.rand(10.0) })
    value[[3, 40]] = UNDEF
    points = CA_INT64(Array.new(25) { rng.rand(-10..110) })
    points[[2, 9]] = UNDEF
    %i[lower upper both].push(nil).each do |exclude|
      w = value.windows(on: key, at: points, before: 3, after: 7, exclude: exclude)
      ref = reference(key, value, points, before: 3, after: 7, exclude: exclude)
      got = w.sum.to_a
      ref.each_with_index do |r, i|
        if r.nil?
          assert_same UNDEF, got[i], "sum #{exclude.inspect} at #{i}"
        else
          assert_in_delta r.sum, got[i], 1e-9, "sum #{exclude.inspect} at #{i}"
        end
      end
      assert_equal ref.map { |r| r.nil? ? UNDEF : r.size }, w.count_not_masked.to_a, "count #{exclude.inspect}"
    end
  end

  def test_a_grid_of_points
    key = CA_INT64([0, 1, 2, 5, 6, 9])
    v = CA_FLOAT64([1, 2, 3, 4, 5, 6])
    w = v.windows(on: key, at: CA_INT64([0, 3, 6, 9, 12]), after: 3, exclude: :upper)
    assert_equal [6.0, 4.0, 5.0, 6.0, 0.0], w.sum.to_a
    assert_equal [2.0, 4.0, 5.0, 6.0, UNDEF], w.mean.to_a
    assert_equal [3, 1, 1, 1, 0], w.elements.to_a
    assert_equal [0, 3, 4, 5, UNDEF], w.first_addr.to_a
    assert_equal [2, 3, 4, 5, UNDEF], w.last_addr.to_a
    assert_equal [[0, 3, 6, 9, 12], [3, 6, 9, 12, 15]], w.bounds.map(&:to_a)
  end

  # Placed at the rows' own keys, the windows are the per-row windows.
  def test_at_the_keys_is_the_per_row_windows
    rng = Random.new(3)
    key = CA_INT64(Array.new(40) { rng.rand(50) })
    v = CA_FLOAT64(Array.new(40) { rng.rand(5.0) })
    per_row = v.windows(on: key, before: 4, after: 2)
    at_keys = v.windows(on: key, at: key, before: 4, after: 2)
    assert_equal per_row.sum.to_a, at_keys.sum.to_a
    assert_equal per_row.elements.to_a, at_keys.elements.to_a
    assert_equal per_row.max.to_a, at_keys.max.to_a
  end

  # is_complete takes the point as the start of the interval grid.
  def test_is_complete_per_point
    key = CA_INT64([0, 1, 2, 3, 6, 7])
    w = CA_FLOAT64([1] * 6).windows(on: key, at: CA_INT64([0, 2, 5]), after: 2, exclude: nil, interval: 1)
    assert_equal [3, 2, 2], w.elements.to_a
    assert_equal [true, false, false], w.is_complete.to_a
  end

  def test_points_in_any_order_and_repeated
    key = CA_INT64([0, 1, 2, 5, 6, 9])
    v = CA_FLOAT64([1, 2, 3, 4, 5, 6])
    w = v.windows(on: key, at: CA_INT64([6, 0, 6, 100]), after: 3, exclude: :upper)
    assert_equal [5.0, 6.0, 5.0, 0.0], w.sum.to_a
  end

  def test_a_masked_or_nan_point_has_no_window
    key = CA_FLOAT64([0, 1, 2])
    pts = CA_FLOAT64([0, Float::NAN, 1, Float::INFINITY])
    pts[2] = UNDEF
    w = CA_FLOAT64([1, 2, 3]).windows(on: key, at: pts, after: 1)
    assert_equal [2.0, UNDEF, UNDEF, UNDEF], w.sum.to_a      # (0, 1] holds key 1
    assert_equal [1, UNDEF, UNDEF, UNDEF], w.elements.to_a
  end

  # An integer key and float points are compared as numbers.
  def test_float_points_on_an_integer_key
    w = CA_FLOAT64([1, 2, 3]).windows(on: CA_INT32([0, 1, 2]), at: CA_FLOAT64([0.5]), after: 1)
    assert_equal [2.0], w.sum.to_a
  end

  def test_no_points
    w = CA_FLOAT64([1, 2]).windows(on: CA_INT64([0, 1]), at: CA_INT64([]), after: 1)
    assert_equal [], w.sum.to_a
  end

  # Time points on another unit than the key are measured on the finer one.
  def test_time_points_on_another_unit
    t = CArray.time(["2024-01-01 00:10", "2024-01-01 23:50", "2024-01-02 00:20", "2024-01-03 05:00"], unit: :m)
    days = CArray.time_range("2024-01-01", "2024-01-03", unit: :D)
    w = CA_FLOAT64([1, 2, 3, 4]).windows(on: t, at: days, after: "1 day", exclude: :upper)
    assert_equal [3.0, 3.0, 4.0], w.sum.to_a
  end

  def test_refusals
    key = CA_INT64([0, 1])
    v = CA_FLOAT64([1, 2])
    assert_raise(ArgumentError) { v.windows(on: key, at: key, after: 1, by: CA_INT32([0, 0])) }
    assert_raise(ArgumentError) { v.windows(on: key, at: [0, 1], after: 1) }
    assert_raise(ArgumentError) { v.windows(on: key, at: CA_INT64([[0, 1]]), after: 1) }
    t = CArray.time(["2024-01-01", "2024-01-02"])
    assert_raise(ArgumentError) { v.windows(on: t, at: key, after: "1 day") }
    assert_raise(ArgumentError) { v.windows(on: key, at: t, after: 1) }
    assert_raise(ArgumentError) { v.windows(on: key, at: CA_CMPLX128([1]), after: 1) }
  end

  # ---- CAFrame#windows(at:) ----

  def frame
    t = CArray.time(["2024-01-01 00:10", "2024-01-01 00:50", "2024-01-01 01:20", "2024-01-01 03:05"], unit: :m)
    CAFrame.new("time" => t, "temp" => CA_FLOAT64([1, 2, 3, 4]), "n" => CA_INT32([1, 1, 1, 1]))
  end

  def grid
    CArray.time_range("2024-01-01 00:00", "2024-01-01 03:00", unit: "1 hour")
  end

  def test_frame_reductions_are_one_row_per_point
    w = frame.windows(on: "time", at: grid, after: "2 hours", exclude: :upper)
    r = w.mean
    assert_equal %w[temp n], r.column_names
    assert_equal "time", r.axis_name
    assert_equal grid.to_a, r.index.to_a
    assert_equal [2.0, 3.0, 4.0, 4.0], r["temp"].to_a
    assert_equal [2.0, 3.0, 4.0, 4.0], w.mean("temp").to_a
    assert_equal [3, 1, 1, 1], w.count("temp").to_a
    assert_equal [0, 2, 3, 3], w.first_addr.to_a
  end

  def test_frame_empty_windows_answer_as_empty_reductions
    w = frame.windows(on: "time", at: grid, after: "30 minutes", exclude: :upper)
    assert_equal [1.0, 3.0, UNDEF, 4.0], w.mean("temp").to_a   # 02:00 holds no row
    assert_equal [1, 1, 0, 1], w.count("temp").to_a
  end

  def test_frame_refuses_at_with_by
    assert_raise(ArgumentError) { frame.windows(on: "time", at: grid, after: "1 hour", by: "n") }
  end

  # A month has no fixed length, so a month key and day points are refused
  # by what they are, as a width in months on a day key is.
  def test_points_in_a_calendar_unit_and_a_fixed_one_are_refused
    df = CAFrame.new("t" => CArray.time(%w[2024-01 2024-02], unit: :M),
                     "v" => CA_FLOAT64([1, 2]))
    days = CArray.time(["2024-02-15"], unit: :D)
    err = assert_raise(ArgumentError) { df.windows(on: "t", at: days, before: "1 month") }
    assert_match(/\Awindows: at: holds points in 1 D/, err.message)
    assert_equal [2.0], df.windows(on: "t", at: days.to_unit(:M), before: "1 month").sum("v").to_a
  end

  # The points are taken when the windows are made, and each result has an
  # index of its own.
  def test_frame_index_is_not_the_array_given
    g = CA_INT64([0, 1, 2])
    df = CAFrame.new("k" => CA_INT64([0, 1, 2]), "v" => CA_FLOAT64([1, 2, 3]))
    w = df.windows(on: "k", at: g, before: 0, exclude: nil)
    r = w.mean
    g[0] = 99
    assert_equal [0, 1, 2], r.index.to_a
    assert_equal [0, 1, 2], w.mean.index.to_a
    r.index[1] = 55
    assert_equal [0, 1, 2], w.mean.index.to_a
  end

  def test_bounds_are_of_the_points_given_then
    g = CA_INT64([0, 1, 2])
    it = CA_FLOAT64([1, 2, 3]).windows(on: CA_INT64([0, 1, 2]), at: g, before: 1)
    g[0] = 99
    assert_equal [[-1, 0, 1], [0, 1, 2]], it.bounds.map(&:to_a)
  end
end
