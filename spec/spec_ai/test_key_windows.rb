$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "carray/frame"
require "test/unit"

# windows(on:): windows bounded by a width of a key, compared with the rows
# a brute-force search puts in each window.
class TestKeyWindows < Test::Unit::TestCase

  def times (*hm)
    CArray.time(hm.map { |s| "2024-01-01 #{s}" }, unit: :m)
  end

  def setup
    @t = times("00:00", "00:10", "00:20", "01:30", "01:40")
    @v = CA_FLOAT64([10, 12, 14, 20, 22])
  end

  def test_a_gap_in_time_shortens_the_window
    w = @v.windows(on: @t, before: "30 minutes")
    assert_equal [10.0, 11.0, 12.0, 20.0, 21.0], w.mean.to_a
    assert_equal [1, 2, 3, 1, 2], w.elements.to_a
  end

  def test_what_each_window_covered
    w = @v.windows(on: @t, before: "30 minutes")
    assert_equal [0, 0, 0, 3, 3], w.first_addr.to_a
    assert_equal [0, 1, 2, 3, 4], w.last_addr.to_a
    assert_equal @t.to_a.values_at(0, 0, 0, 3, 3), w.first_key.to_a
    lower, upper = w.bounds
    assert_equal (@t - "30 minutes").to_a, lower.to_a
    assert_equal @t.to_a, upper.to_a
  end

  def test_is_complete_asks_for_every_grid_point
    w = @v.windows(on: @t, before: "20 minutes", interval: "10 minutes")
    assert_equal [false, true, true, false, true], w.is_complete.to_a
    assert_raise(ArgumentError) { @v.windows(on: @t, before: "20 minutes").is_complete }
  end

  def test_is_complete_is_not_fooled_by_a_repeated_or_off_grid_key
    t = times("00:00", "00:10", "00:10", "00:25", "00:30")
    w = CArray.float64(5).seq.windows(on: t, before: "20 minutes", interval: "10 minutes")
    # 00:10 twice is one grid point; 00:25 is off the grid of 00:30.
    assert_equal [false, true, true, false, false], w.is_complete.to_a
  end

  def test_exclude_picks_the_ends
    k = CA_INT64([0, 1, 2, 3])
    v = CA_INT64([1, 10, 100, 1000])
    sums = ->(**kw) { v.windows(on: k, **kw).sum.to_a }
    assert_equal [1, 10, 100, 1000],   sums.(before: 1)                       # (t-1, t]
    assert_equal [1, 11, 110, 1100],   sums.(before: 1, exclude: nil)         # [t-1, t]
    assert_equal [1, 10, 100, 1000],   sums.(before: 1, after: 1, exclude: :both)
    assert_equal [10, 100, 1000, 0],   sums.(after: 1)                        # (t, t+1]
    assert_equal [1, 10, 100, 1000],   sums.(after: 1, exclude: :upper)       # [t, t+1)
    assert_equal [11, 110, 1100, 1000], sums.(after: 1, exclude: nil)         # [t, t+1]
  end

  def test_unsorted_keys_answer_in_row_order
    k = CA_INT64([3, 1, 2])
    v = CA_FLOAT64([30, 10, 20])
    assert_equal [50.0, 10.0, 30.0], v.windows(on: k, before: 1, exclude: nil).sum.to_a
  end

  def test_by_keeps_each_window_in_its_group
    k = CA_INT64([1, 1, 2, 2])
    g = CA_OBJECT(%w[a b a b])
    v = CA_FLOAT64([1, 10, 2, 20])
    assert_equal [1.0, 10.0, 3.0, 30.0], v.windows(on: k, before: 1, exclude: nil, by: g).sum.to_a
  end

  def test_a_masked_key_has_no_window_and_is_in_none
    k = CA_INT64([1, 2, 3])
    k[1] = UNDEF
    v = CA_FLOAT64([1, 2, 3])
    w = v.windows(on: k, before: 2, exclude: nil)
    assert_equal [1.0, UNDEF, 4.0], w.sum.to_a
    assert_equal [1, UNDEF, 2], w.elements.to_a
  end

  def test_a_masked_value_is_in_the_window_but_not_in_the_reduction
    v = @v.copy
    v[1] = UNDEF
    w = v.windows(on: @t, before: "30 minutes")
    assert_equal [1, 2, 3, 1, 2], w.elements.to_a
    assert_equal [10.0, 10.0, 12.0, 20.0, 21.0], w.mean.to_a
  end

  def test_a_width_finer_than_the_key_unit
    h = CArray.time(["2024-01-01 00:00", "2024-01-01 01:00", "2024-01-01 02:00"], unit: :h)
    assert_equal [1.0, 3.0, 5.0], CA_FLOAT64([1, 2, 3]).windows(on: h, before: "90 minutes").sum.to_a
  end

  def test_a_time_value_answers_as_time
    w = @t.windows(on: @t, before: "30 minutes")
    assert_equal @t.to_a.values_at(0, 0, 0, 3, 3), w.min.to_a
  end

  def test_refusals
    k = CA_INT64([1, 2, 3])
    v = CA_FLOAT64([1, 2, 3])
    assert_raise(ArgumentError) { v.windows(on: @t[0..2], before: 3600) }
    assert_raise(ArgumentError) { v.windows(on: k, before: "1 hour") }
    assert_raise(ArgumentError) { v.windows(-1..1, on: k, before: 1) }
    assert_raise(ArgumentError) { v.windows(before: 1) }
    assert_raise(ArgumentError) { v.windows(on: k) }
    assert_raise(ArgumentError) { v.windows(on: k, before: -1) }
    assert_raise(ArgumentError) { v.windows(on: k, before: 3, interval: 2) }
    assert_raise(ArgumentError) { v.windows(on: @t[0..2], before: "1 month") }
    assert_raise(ArgumentError) { v.windows(on: CA_OBJECT(%w[a b c]), before: 1) }
  end

  def test_agrees_with_a_brute_force_search
    srand 3
    200.times do
      n    = rand(0..9)
      keys = Array.new(n) { rand < 0.1 ? nil : rand(0..12) }
      grp  = Array.new(n) { rand < 0.1 ? nil : %w[a b][rand(2)] }
      val  = Array.new(n) { rand < 0.15 ? nil : rand(100).to_f }
      k = CA_INT64(keys.map { |x| x || 0 })
      g = CA_OBJECT(grp.map { |x| x || "z" })
      v = CA_FLOAT64(val.map { |x| x || 0.0 })
      n.times do |i|
        k[i] = UNDEF if keys[i].nil?
        g[i] = UNDEF if grp[i].nil?
        v[i] = UNDEF if val[i].nil?
      end
      [[2, nil, :lower], [3, 1, :both], [nil, 2, :upper], [0, 0, nil]].each do |b, a, ex|
        w = v.windows(on: k, before: b, after: a, exclude: ex, by: g)
        lo_w, hi_w = b || 0, a || 0
        sums  = []
        sizes = []
        n.times do |i|
          if keys[i].nil? || grp[i].nil?
            sums << UNDEF
            sizes << UNDEF
            next
          end
          t = keys[i]
          inw = (0...n).select do |j|
            next false if keys[j].nil? || grp[j] != grp[i]
            x = keys[j]
            (ex == :lower || ex == :both ? x > t - lo_w : x >= t - lo_w) &&
              (ex == :upper || ex == :both ? x < t + hi_w : x <= t + hi_w)
          end
          sums << inw.map { |j| val[j] }.compact.sum.to_f
          sizes << inw.size
        end
        assert_equal sums, w.sum.to_a
        assert_equal sizes, w.elements.to_a
      end
    end
  end

  # A float key is compared with the bounds exactly: on a decimal grid a key
  # that misses a bound in the last bit falls inside the window.
  def test_a_float_key_meets_the_bounds_exactly
    k = CArray.float64(11) { |i| i * 0.1 }
    w = CArray.float64(11).seq!.windows(on: k, before: 0.3, interval: 0.1)
    assert_equal [1, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4], w.elements.to_a
    assert_equal false, w.is_complete[10]
  end

  # An infinite float key, as a NaN one, is in no window and has none.
  def test_an_infinite_key_is_in_no_window
    inf = Float::INFINITY
    v = CA_FLOAT64([1, 10, 100, 1000])
    w = v.windows(on: CA_FLOAT64([-inf, 0, 1, inf]), before: inf, exclude: nil)
    assert_equal [UNDEF, 1, 2, UNDEF], w.elements.to_a
    assert_equal [UNDEF, 10.0, 110.0, UNDEF], w.sum.to_a
  end

  # A width the key's unit does not divide gives bounds on the finer unit,
  # the bounds the windows were cut at.
  def test_bounds_on_a_unit_finer_than_the_key
    t = CArray.time(["2024-01-01 00:00", "2024-01-01 00:10"], unit: "10 minutes")
    lower, = CA_FLOAT64([1, 2]).windows(on: t, before: "15 minutes").bounds
    assert_equal %w[2023-12-31T23:45:00Z 2023-12-31T23:55:00Z], lower.to_a.map(&:to_s)
    y = CArray.time(%w[2020 2021], unit: :Y)
    lower, = CA_FLOAT64([1, 2]).windows(on: y, before: "6 months").bounds
    assert_equal %w[2019-07 2020-07], lower.to_a.map(&:to_s)
    h = CArray.time(["2024-01-01 00:00"], unit: :m)
    lower, = CA_FLOAT64([1]).windows(on: h, before: "1 hour").bounds
    assert_equal "m", lower.unit.to_s
  end

  # A bound beyond the range of an int64 key holds every key on that side,
  # rather than wrapping round and emptying the windows that follow.
  def test_bounds_beyond_int64_hold_every_key
    v = CA_FLOAT64([1, 10, 100])
    w = v.windows(on: CA_INT64([-5, 0, 3]), before: 2**63 - 1, exclude: nil)
    assert_equal [1, 2, 3], w.elements.to_a
    assert_equal [1.0, 11.0, 111.0], w.sum.to_a
    w = v.windows(on: CA_INT64([-2**63, 0, 1]), before: 1, exclude: nil)
    assert_equal [1, 1, 2], w.elements.to_a
    w = v.windows(on: CA_INT64([2**63 - 2, 2**63 - 1, 0]), after: 2**63 - 1, exclude: nil)
    assert_equal [2, 1, 3], w.elements.to_a
    t = CArray.time(%w[1900-01-01 1950-01-01 2000-01-01], unit: :ns)
    assert_equal [1, 2, 3], v.windows(on: t, before: "100000 days", exclude: nil).elements.to_a
  end
end

class TestCAFrameWindows < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(%w[a b a b a]),
      "time"    => CArray.time(["2024-01-01 00:00", "2024-01-01 00:00", "2024-01-01 00:10",
                                "2024-01-01 00:20", "2024-01-01 01:30"], unit: :m),
      "temp"    => CA_FLOAT64([10, 20, 12, 22, 30]),
      "name"    => CA_OBJECT(%w[x y z w v]))
  end

  def test_named_and_frame_wide
    w = @df.windows(on: "time", before: "30 minutes", by: "station")
    assert_equal [10.0, 20.0, 11.0, 21.0, 30.0], w.mean("temp").to_a
    frame = w.mean
    assert_equal ["temp"], frame.column_names
    assert_equal [1, 1, 2, 2, 1], w.elements.to_a
    assert_equal [10.0, 20.0, 12.0, 22.0, 30.0], w["temp"].max.to_a
  end

  def test_a_column_without_the_reduction_is_refused_by_name
    w = @df.windows(on: "time", before: "30 minutes")
    assert_raise(CArray::DataTypeError) { w.mean("name") }
    assert_raise(TypeError) { @df.windows(on: :time, before: "1 hour") }
  end
end
