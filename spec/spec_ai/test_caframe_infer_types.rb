require "test/unit"
require "carray"
require "stringio"

# CAFrame#infer_types / from_csv(types: :infer): a text column becomes
# int64 or float64 when every cell that is not missing reads as a number of
# that kind; anything else stays text.
class TestCAFrameInferTypes < Test::Unit::TestCase
  CSV_TEXT = <<~CSV
    station,code,temp,count,id,flag,empty
    tokyo,007,22.1,3,12345678901234567890,A,
    osaka,012,,4,12345678901234567891,B,
    nagoya,105,21.0,,12345678901234567892,,
  CSV

  def frame(text = CSV_TEXT, **opts)
    CAFrame.from_csv(StringIO.new(text), **opts)
  end

  def infer(cells)
    CAFrame.new("a" => CA_OBJECT(cells)).infer_types["a"]
  end

  def test_infer_types_lists_number_columns
    assert_equal({ "temp" => :float64, "count" => :int64 }, frame.infer_types)
  end

  def test_types_infer_casts_them
    df = frame(types: :infer)
    assert_equal :float64, df["temp"].data_type
    assert_equal [22.1, UNDEF, 21.0], df["temp"].to_a
    assert_equal :int64, df["count"].data_type
    assert_equal [3, 4, UNDEF], df["count"].to_a
  end

  def test_codes_identifiers_and_text_stay_text
    df = frame(types: :infer)
    %w[station code id flag empty].each { |k| assert_equal :object, df[k].data_type, k }
    assert_equal ["007", "012", "105"], df["code"].to_a
  end

  def test_kinds
    assert_equal :int64,   infer(["1", "-2", "+3", " 4 ", "0", "-0"])
    assert_equal :float64, infer(["1", "2.5"])
    assert_equal :float64, infer(["1e3", ".5", "nan", "-Inf"])
    assert_equal :float64, infer(["1.0"])
    assert_nil infer(["007"])
    assert_nil infer(["007.5"])
    assert_nil infer(["-01"])
    assert_nil infer(["9223372036854775808"])
    assert_nil infer(["1", "x"])
    assert_nil infer(["0x10"])
    assert_nil infer(["1_000"])
    assert_equal :int64, infer(["9223372036854775807", "-9223372036854775808"])
  end

  def test_missing_cells_say_nothing
    assert_equal :int64, infer(["1", "", "  ", nil])
    assert_nil infer(["", nil])
    col = CA_OBJECT(["1", "x"])
    col[1] = UNDEF
    assert_equal({ "a" => :int64 }, CAFrame.new("a" => col).infer_types)
  end

  def test_ruby_numbers_in_an_object_column
    assert_equal :int64,   infer([1, 2])
    assert_equal :float64, infer([1, 2.5])
    assert_equal :int64,   infer([1, "2"])
    assert_nil infer([1, :x])
  end

  def test_typed_columns_are_not_listed
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_OBJECT(["1", "2"]))
    assert_equal({ "b" => :int64 }, df.infer_types)
  end

  def test_view_column
    base = CA_OBJECT([["x", "1"], ["y", "2"]])
    assert_equal({ "a" => :int64 }, CAFrame.new("a" => base[nil, 1]).infer_types)
  end

  def test_from_records
    df = CAFrame.from_records([{ "a" => "1" }, { "a" => "2" }], types: :infer)
    assert_equal :int64, df["a"].data_type
  end

  def test_types_must_be_a_map_or_infer
    assert_raise(ArgumentError) { frame(types: :auto) }
  end
end

# cast(name => :time) and the :time that infer_types gives.
class TestCAFrameCastTime < Test::Unit::TestCase
  CSV_TEXT = <<~CSV
    date,stamp,fine,dmy,bad
    2024-01-01,2024-01-01 00:00:00,2024-01-01T00:00:00.123Z,01/02/2024,2024-01-01
    2024-01-02,2024/01/01 01:30,2024-01-01T00:00:00.5+09:00,02/02/2024,2024-13-01
    ,,,,x
  CSV

  def frame
    CAFrame.from_csv(StringIO.new(CSV_TEXT))
  end

  def strings(col)
    col.to_a.map(&:to_s)
  end

  def test_infer_types_reads_year_first_dates_and_times
    assert_equal({ "date" => :time, "stamp" => :time, "fine" => :time }, frame.infer_types)
  end

  def test_unit_follows_the_text
    df = frame.cast("date" => :time, "stamp" => :time, "fine" => :time)
    assert_kind_of CATime, df["date"]
    assert_equal ["2024-01-01", "2024-01-02", "UNDEF"], strings(df["date"])
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T01:30:00Z", "UNDEF"], strings(df["stamp"])
    assert_equal ["2024-01-01T00:00:00.123Z", "2023-12-31T15:00:00.500Z", "UNDEF"],
                 strings(df["fine"])
  end

  def test_types_infer_casts_time
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: :infer)
    assert_kind_of CATime, df["stamp"]
    assert_equal :object, df["dmy"].data_type
    assert_equal :object, df["bad"].data_type
  end

  def test_on_error
    e = assert_raise(ArgumentError) { frame.cast("bad" => :time, on_error: :raise) }
    assert_match(/column "bad", row 1 "2024-13-01" cannot be read as time/, e.message)
    df = frame
    _out, err = capture_output { df.cast("bad" => :time, on_error: :warn) }
    assert_match(/2 cells cannot be read as time/, err)
    assert_equal ["2024-01-01", "UNDEF", "UNDEF"], strings(df["bad"])
  end

  def test_parse_to_time_takes_on_error
    assert_raise(ArgumentError) { frame.parse_to_time("bad", on_error: :raise) }
    assert_nothing_raised { frame.parse_to_time("date", on_error: :raise) }
  end

  def test_a_column_that_is_not_text
    df = CAFrame.new("t" => CA_FLOAT64([1.0]))
    assert_raise(ArgumentError) { df.cast("t" => :time) }
  end

  def times(cells, *args, **opts)
    df = CAFrame.new("t" => CA_OBJECT(cells))
    df.parse_to_time("t", *args, **opts)
    strings(df["t"])
  end

  # Year-first text without zero padding, as a spreadsheet writes it.
  def test_year_first_without_padding
    assert_equal ["2024-01-02T03:04:00Z", "2024-01-02T00:00:00Z"],
                 times(["2024/1/2 3:04", "2024/1/2"])
  end

  def test_zones
    assert_equal ["2024-01-01T03:00:00Z", "2024-01-01T13:30:00Z",
                  "2023-12-31T23:30:00Z", "2024-01-01T12:00:00Z"],
                 times(["2024-01-01 12:00:00+09:00", "2024-01-01 12:00 -0130",
                        "2024-01-01T00:30+01", "2024-01-01T12:00Z"])
  end

  def test_what_is_not_read_without_a_format
    cells = ["01/02/2024", "Jan 2, 2024", "2024-02-30", "2024-01-01 24:00",
             "20240101", "2024-1-01/02", "2024-01-01T", "2024-01-01Z"]
    assert_equal ["UNDEF"] * cells.size, times(cells)
  end

  def test_a_format_and_mixed
    assert_equal ["2024-02-01T00:00:00Z"], times(["01/02/2024"], "%d/%m/%Y")
    assert_equal ["2024-01-02T00:00:00Z"], times(["Jan 2, 2024"], :mixed)
    assert_raise(ArgumentError) { times(["2024-01-01"], :guess) }
  end

  def test_a_unit_the_reader_does_not_write
    assert_equal ["2024-01-01T12:00:00Z", "1969-12-31T23:00:00Z"],
                 times(["2024-01-01 12:34:56", "1969-12-31 23:59:59"], unit: :h)
  end

  def test_a_coarser_unit_floors
    assert_equal ["2024-01-01", "1969-12-31"],
                 times(["2024-01-01 12:34:56", "1969-12-31 23:59:59"], unit: :D)
  end

  # The reader agrees with CArray.time on year-first text.
  def test_agrees_with_carray_time
    srand(1)
    texts = Array.new(500) do
      Time.at(rand(-4_000_000_000..8_000_000_000), rand(1000) * 1000, :usec)
          .utc.strftime("%Y-%m-%dT%H:%M:%S.%3N")
    end
    expected = CArray.time(CA_OBJECT(texts), unit: :ms).to_a.map(&:to_s)
    assert_equal expected, times(texts)
  end
end

# parse_to_time(name, :infer) and infer_time_format: the first cell gives the
# candidate formats, later cells drop those they do not fit.
class TestCAFrameInferTimeFormat < Test::Unit::TestCase
  def frame(cells)
    CAFrame.new("t" => CA_OBJECT(cells))
  end

  def format_of(cells)
    frame(cells).infer_time_format("t")
  end

  def times(cells, **opts)
    df = frame(cells)
    df.parse_to_time("t", :infer, **opts)
    df["t"].to_a.map(&:to_s)
  end

  def test_a_later_cell_decides
    assert_equal "%d/%m/%Y", format_of(["01/02/2024", "13/02/2024"])
    assert_equal "%m/%d/%Y", format_of(["01/02/2024", "02/01/2024", "02/13/2024"])
    assert_equal ["2024-02-01", "UNDEF", "UNDEF", "2024-02-13"],
                 times(["01/02/2024", "", nil, "13/02/2024"])
  end

  def test_ambiguous_to_the_end_raises
    e = assert_raise(ArgumentError) { format_of(["01/02/2024", "03/04/2024"]) }
    assert_match(/"%d\/%m\/%Y" or "%m\/%d\/%Y"/, e.message)
  end

  def test_formats
    assert_equal "%d/%m/%Y %I:%M %p", format_of(["1/2/2024 3:04 PM", "13/2/2024 11:00 AM"])
    assert_equal "%b %d, %Y", format_of(["Jan 2, 2024"])
    assert_equal "%d %b %Y", format_of(["2 Jan 2024", "13 February 2024"])
    assert_equal "%Y%m%d", format_of(["20240102"])
    assert_equal "%d/%m/%y", format_of(["13/02/24"])
  end

  def test_unit_follows_the_text
    assert_equal ["2024-02-01T15:04:00Z"], times(["1/2/2024 3:04 PM", "13/2/2024 11:00 AM"]).first(1)
    assert_equal ["2024-02-01T12:34:56.123456Z", "2024-02-13T00:00:00.500000Z"],
                 times(["01/02/2024 12:34:56.123456", "13/02/2024 00:00:00.5"])
    assert_equal ["2024-01-02"], times(["Jan 2, 2024"])
  end

  def test_year_first_needs_no_format
    assert_nil format_of(["2024-01-02", "2024/1/3 3:04"])
    assert_equal ["2024-01-02T00:00:00Z", "2024-01-03T03:04:00Z"],
                 times(["2024-01-02", "2024/1/3 3:04"])
  end

  # A cell not in the chosen format raises, whatever on_error says.
  def test_a_cell_out_of_format_raises
    [["13/02/2024", "01-02-2024"], ["13/02/2024", "31/02/2024"],
     ["13/02/2024", "01/02/24"], ["2024-01-02", "Jan 3, 2024"]].each do |cells|
      assert_raise(ArgumentError, cells.inspect) { times(cells, on_error: :mask) }
    end
  end

  def test_no_candidate_for_the_first_cell
    e = assert_raise(ArgumentError) { format_of(["hello", "13/02/2024"]) }
    assert_match(/cannot infer a time format from "hello"/, e.message)
  end

  def test_no_present_cell
    assert_nil format_of(["", nil])
    assert_equal ["UNDEF", "UNDEF"], times(["", nil])
  end
end
