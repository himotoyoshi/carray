require "test/unit"
require "carray"
require "tmpdir"

# Second 60 is the leap second.  The year-first reader that CAFrame's CSV and
# cast(name => :time) use carries it into the next minute, as CArray.time does.
class TestTimeTextLeapSecond < Test::Unit::TestCase

  CELLS = %w[2016-12-31T23:59:60 2016-12-31T23:59:60.25 2016-06-30T12:30:60
             2016-12-31T23:59:60+09:00 2016-12-31T23:59:60-05:00
             2016-12-31T23:59:59]

  def frame_times (cells)
    CAFrame.new({ "t" => CA_OBJECT(cells) }).cast("t" => :time)["t"]
  end

  def test_cast_agrees_with_carray_time
    CELLS.each do |c|
      assert_equal CArray.time([c]).to_a.map(&:to_s), frame_times([c]).to_a.map(&:to_s), c
    end
  end

  def test_leap_second_carries_into_the_new_year
    assert_equal ["2017-01-01T00:00:00Z"], frame_times(["2016-12-31T23:59:60"]).to_a.map(&:to_s)
  end

  def test_from_csv_reads_the_leap_second
    Dir.mktmpdir do |dir|
      path = File.join(dir, "leap.csv")
      File.write(path, "t\n2016-12-31T23:59:60\n")
      t = CAFrame.from_csv(path, types: { "t" => :time })["t"]
      assert_equal ["2017-01-01T00:00:00Z"], t.to_a.map(&:to_s)
    end
  end

  def test_second_61_is_unreadable
    assert_true frame_times(["2016-12-31T23:59:61"]).is_masked[0]
  end

end
