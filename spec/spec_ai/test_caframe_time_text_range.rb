require "test/unit"
require "stringio"
require "carray"

# Year-first time text whose finest cell needs a unit that cannot hold
# every date used to mask the far-out dates without a word.
class TestCAFrameTimeTextRange < Test::Unit::TestCase
  CELLS = ["2300-01-01", "1650-06-01", "2024-01-01 00:00:00.1234567"]

  def frame(cells = CELLS)
    CAFrame.new("t" => CA_OBJECT(cells))
  end

  def test_cast_raises_naming_the_column_and_the_cell
    err = assert_raise(RangeError) { frame.cast("t" => :time) }
    assert_match(/column "t": time "2300-01-01" does not fit int64 ticks of ns/, err.message)
    assert_match(/unit:/, err.message)
  end

  def test_it_raises_under_every_policy
    %i[mask warn raise].each do |policy|
      assert_raise(RangeError) { frame.cast("t" => :time, on_error: policy) }
    end
  end

  def test_the_frame_is_left_as_it_was
    df = frame
    assert_raise(RangeError) { df.cast("t" => :time) }
    assert_equal CELLS, df["t"].to_a
  end

  def test_a_coarser_unit_reads_every_date
    t = frame.parse_to_time("t", unit: :us)["t"]
    assert_equal ["2300-01-01T00:00:00.000000Z", "1650-06-01T00:00:00.000000Z",
                  "2024-01-01T00:00:00.123456Z"], t.to_a.map(&:to_s)
  end

  def test_infer_types_still_calls_it_time
    assert_equal({ "t" => :time }, frame.infer_types)
  end

  def test_infer_types_does_not_call_a_column_with_text_in_it_time
    assert_equal({}, frame(CELLS + ["x"]).infer_types)
  end

  def test_without_the_finest_cell_the_dates_read
    t = frame(CELLS[0, 2]).cast("t" => :time)["t"]
    assert_equal ["2300-01-01", "1650-06-01"], t.to_a.map(&:to_s)
  end

  def test_unreadable_text_is_still_masked
    t = frame(["2024-01-01", "x"]).cast("t" => :time)["t"]
    assert_equal [false, true], t.is_masked.to_a
  end

  def test_from_csv_types_infer_raises_too
    csv = "t\n2300-01-01\n2024-01-01 00:00:00.1234567\n"
    assert_raise(RangeError) { CAFrame.from_csv(StringIO.new(csv), types: :infer) }
  end
end
