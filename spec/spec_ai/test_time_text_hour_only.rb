require "test/unit"
require "carray"
require "stringio"

# An hour alone after the date ("2024-01-01T05") is a time; text with a time
# after the date that is not read as one is refused, not read as midnight.
class TestTimeTextHourOnly < Test::Unit::TestCase
  def test_an_hour_alone_is_read
    assert_equal "2024-01-01T05:00:00Z", CArray.time(["2024-01-01T05"], unit: :s)[0].to_s
    assert_equal "2024-01-01T05:00:00Z", CArray.time(["2024-01-01T05Z"], unit: :s)[0].to_s
    assert_equal "2023-12-31T20:00:00Z", CArray.time(["2024-01-01T05+09"], unit: :s)[0].to_s
    assert_equal "2023-12-31T19:30:00Z", CArray.time(["2024-01-01T05+09:30"], unit: :s)[0].to_s
  end

  def test_an_unread_time_is_refused
    %w[2024-01-01T0130 2024-01-01T25 2024-01-01T1].each do |s|
      assert_raise(ArgumentError, s) { CArray.time([s], unit: :s) }
    end
    t = CArray.time(["2024-01-01T25", "2024-01-01T03"], unit: :h, on_error: :mask)
    assert_equal [true, false], t.is_masked.to_a
  end

  def test_dates_without_a_time_are_unchanged
    assert_equal "2024-01-01", CArray.time(["Jan 1 2024"], unit: :D)[0].to_s
    assert_equal "2024-01-01", CArray.time(["2024-01-01"], unit: :D)[0].to_s
  end

  def test_the_frame_reader_agrees
    csv = "t\n2024-01-01T05\n2024-01-01T25\n2024-01-01T05+09\n"
    t = CAFrame.from_csv(StringIO.new(csv), types: { "t" => :time })["t"]
    assert_equal "2024-01-01T05:00:00Z", t[0].to_s
    assert_equal [false, true, false], t.is_masked.to_a
    assert_equal "2023-12-31T20:00:00Z", t[2].to_s
  end
end
