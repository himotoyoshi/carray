require "test/unit"
require "carray"

# A match by distance treats what has no distance alike at every entry:
# a NaN (or masked) key matches nothing and is in no window, an infinite
# key keeps its place in a nearest search; and the length the match is
# limited by -- tolerance:, a window's before: / after: / interval: -- is
# read by one part, a length of the key's kind not below 0.  tolerance:
# had taken NaN (every match kept) and a negative length (every match
# dropped) where a window refused them, and "0 minutes" was refused with
# no name where a zero CATimedelta was taken.
class TestDistanceLimit < Test::Unit::TestCase

  NAN = Float::NAN
  INF = Float::INFINITY

  def test_a_nan_key_matches_nothing_at_every_entry
    ref = CA_FLOAT64([1, 2, NAN, 4, INF])
    q = CA_FLOAT64([NAN, 2.2, INF, -INF, 5])
    assert_equal [UNDEF, 1, 4, 0, 3], q.locate_nearest_addr(ref).to_a
    assert_equal [UNDEF, 1, 4, UNDEF, 3], q.locate_nearest_addr(ref, direction: :floor).to_a
    assert_equal [UNDEF, 1, 4, 0, 3], CArray.align_nearest_addr(ref, grid: q)[1].to_a
    l = CAFrame.new("t" => CA_FLOAT64([NAN, 2.2, INF, 1]), "s" => CA_OBJECT(%w[a a a a]))
    r = CAFrame.new("t" => CA_FLOAT64([1, NAN, INF, 2]), "s" => CA_OBJECT(%w[a a a a]),
                    "v" => CA_INT32([10, 20, 30, 40]))
    assert_equal [UNDEF, 40, 30, 10], l.join_asof(r, on: "t")["v"].to_a
    assert_equal [UNDEF, 40, 30, 10], l.join_asof(r, on: "t", by: "s")["v"].to_a
    k = CA_FLOAT64([1, NAN, 2, INF, 3, -INF])
    v = CA_FLOAT64([1, 1, 1, 1, 1, 1])
    assert_equal [1, UNDEF, 2, UNDEF, 3, UNDEF],
                 v.windows(on: k, before: 2, after: 0, exclude: nil).count.to_a
    assert_equal [1.0, UNDEF, 2.0, UNDEF, 3.0, UNDEF],
                 CAFrame.new("k" => k, "v" => v).windows(on: "k", before: 2, after: 0, exclude: nil).sum("v").to_a
  end

  def entries (key, ref)
    one = CArray.float64(key.elements).fill(1)
    {
      "tolerance:"       => ->(w) { key.locate_nearest_addr(ref, tolerance: w) },
      "windows: before:" => ->(w) { one.windows(on: key, before: w) },
      "windows: after:"  => ->(w) { one.windows(on: key, before: nil, after: w) },
    }
  end

  def test_a_number_key_refuses_what_is_not_a_length_alike
    key = CA_FLOAT64([1, 2])
    entries(key, key).each do |label, call|
      [NAN, -1].each do |w|
        err = assert_raise(ArgumentError, label) { call.(w) }
        assert_equal "#{label} is a number not below 0 (got #{w.inspect})", err.message
      end
      err = assert_raise(ArgumentError, label) { call.("1 hour") }
      assert_equal "#{label} \"1 hour\" is a duration, but the key is float64; give a number",
                   err.message
      assert_nothing_raised(label) { call.(0) }
      assert_nothing_raised(label) { call.(INF) }
    end
    err = assert_raise(ArgumentError) { key.locate_nearest_addr(key, tolerance: 1, direction: :up) }
    assert_match(/direction/, err.message)
  end

  def test_a_time_key_takes_a_duration_not_below_0_alike
    key = CArray.time(["2024-01-01 00:00", "2024-01-01 00:10"], unit: :m)
    entries(key, key).each do |label, call|
      err = assert_raise(ArgumentError, label) { call.(5) }
      assert_match(/\A#{label} a time key needs a duration/, err.message)
      err = assert_raise(ArgumentError, label) { call.(CATimedelta::Element.new(-5, :m)) }
      assert_match(/\A#{label} is a duration not below 0/, err.message)
      err = assert_raise(ArgumentError, label) { call.("-10 minutes") }
      assert_match(/\A#{label} "-10 minutes" is not a duration/, err.message)
      assert_nothing_raised(label) { call.("0 minutes") }
      assert_nothing_raised(label) { call.(CATimedelta::Element.new(0, :m)) }
    end
    assert_equal [0, 1], key.locate_nearest_addr(key, tolerance: "0 minutes").to_a
    assert_equal [1.0, 1.0],
                 CA_FLOAT64([1, 1]).windows(on: key, before: "5 minutes", after: "0 minutes").sum.to_a
  end
end
