require "test/unit"
require "carray"

# CArray.time over an array parses each String into date fields and turns
# the fields into ticks for the whole array at once. These pin that the
# answer is the one a cell-by-cell tick_index gives.
class TestTimeParseArray < Test::Unit::TestCase
  def one_by_one(x, unit, format)
    res = CATime::Resolution.parse(unit)
    x.flatten.to_a.map do |s|
      next "UNDEF" if s.nil? || UNDEF.equal?(s)
      begin
        CA_INT64([CATimeLiteral.tick_index(s, res, format)]).time(unit: res)[0].to_s
      rescue ArgumentError, TypeError
        "UNDEF"
      end
    end
  end

  def samples
    srand(5)
    Array.new(300) do
      Time.at(rand(-6_000_000_000..9_000_000_000), rand(1_000_000), :usec).utc
    end
  end

  def test_formats_and_units_agree_with_cell_by_cell
    cases = {
      "%d/%m/%Y %H:%M:%S"    => samples.map { |t| t.strftime("%d/%m/%Y %H:%M:%S") },
      "%Y-%m-%dT%H:%M:%S.%N" => samples.map { |t| t.strftime("%Y-%m-%dT%H:%M:%S.%6N") },
      "%m/%d/%y %I:%M %p"    => samples.map { |t| t.strftime("%m/%d/%y %I:%M %p") },
      "%Y-%m-%d %H:%M %z"    => samples.map { |t| t.getlocal(-5 * 3600).strftime("%Y-%m-%d %H:%M %z") },
      nil                    => samples.map { |t| t.strftime("%b %-d, %Y %H:%M:%S") } +
                                ["2024-03", "2024", "x", "2019-02-31", nil],
    }
    units = [:s, :ms, :us, :ns, :D, :h, "10 minutes", :W, :M, :Y, "3 months"]
    cases.each do |format, texts|
      x = CA_OBJECT(texts)
      units.each do |unit|
        got = CArray.time(x, unit: unit, format: format, on_error: :mask).to_a.map(&:to_s)
        assert_equal one_by_one(x, unit, format), got, "#{format.inspect} #{unit}"
      end
    end
  end

  # Texts at the edges of what a format takes, read in C and through
  # Date._strptime cell by cell. A cell the C reader leaves to
  # Date._strptime (a zone named for a place, "+9") is read there.
  def test_edges_agree_with_cell_by_cell
    edges = ["", " ", "2024-1-2", "2024-01-02x", "2024-01-02 ", " 2024-01-02",
             "2024-02-30", "2023-02-29", "2024-13-01", "-2024-01-02", "+2024-01-02",
             "02024-01-02", "1/2/2024 12:00 AM", "1/2/2024 12:00 PM",
             "1/2/2024 12:00 a.m.", "1/2/2024 13:00 PM",
             "Tue, 02 Jan 2024 15:04:05 +0900", "Tue, 02 Jan 2024 15:04:05 +09:00",
             "Tue, 02 Jan 2024 15:04:05 Z", "Tue, 02 Jan 2024 15:04:05 UTC",
             "Tue, 02 Jan 2024 15:04:05 JST", "Tue, 02 Jan 2024 15:04:05 +9",
             "Tue, 02 Jan 2024 15:04:05 UTC+9", "tue, 02 jan 2024 15:04:05 +0000",
             "January  2, 2024", "Jan  2, 2024", "Sept 2, 2024",
             "2024-01-02T24:00:00.5", "2024-01-02T23:59:60.123456789123",
             "2024-01-02 23:59:59.-5", "20240102", "2024010215",
             "12/31/99 11:59 pm", "31.12.2024 7:05", "2024/1/2  3:04:05 am"]
    formats = ["%Y-%m-%d", "%d/%m/%Y %H:%M:%S", "%m/%d/%y %I:%M %p",
               "%Y%m%d%H%M%S", "%Y-%m-%dT%H:%M:%S.%N", "%a, %d %b %Y %H:%M:%S %z",
               "%B %e, %Y", "%F %T", "%D %R", "%d.%m.%Y %k:%M", "%Y/%m/%d %l:%M:%S %P"]
    x = CA_OBJECT(edges)
    formats.each do |format|
      got = CArray.time(x, unit: :ms, format: format, on_error: :mask).to_a.map(&:to_s)
      assert_equal one_by_one(x, :ms, format), got, format
    end
  end

  def test_shape_and_missing_cells
    x = CA_OBJECT([["2024-01-01", nil], ["x", "2024-01-02"]])
    t = CArray.time(x, unit: :D, on_error: :mask)
    assert_equal [2, 2], t.shape
    assert_equal [["2024-01-01", "UNDEF"], ["UNDEF", "2024-01-02"]],
                 t.to_a.map { |row| row.map(&:to_s) }
    assert_raise(ArgumentError) { CArray.time(x, unit: :D) }
  end

  def test_no_mask_when_every_cell_reads
    assert_false CArray.time(CA_OBJECT(["2024-01-01"]), unit: :D).has_mask?
  end

  def test_cells_that_are_not_strings
    t = CArray.time(CA_OBJECT([Time.utc(2024, 1, 1), "2024-01-02"]), unit: :D)
    assert_equal ["2024-01-01", "2024-01-02"], t.to_a.map(&:to_s)
  end

  # Text left over after the format is not a time in that format; spaces
  # are only spaces.
  def test_text_left_over_after_the_format
    t = CArray.time(CA_OBJECT(["13/02/2024xyz", "13/02/2024 "]),
                    unit: :D, format: "%d/%m/%Y", on_error: :mask)
    assert_equal ["UNDEF", "2024-02-13"], t.to_a.map(&:to_s)
  end

  def test_a_time_beyond_int64_ticks_raises
    assert_raise(RangeError) do
      CArray.time(CA_OBJECT(["9999-12-31"]), unit: :ns, format: "%Y-%m-%d", on_error: :mask)
    end
  end

  # With a format, an Integer is the digits it is written with, not Unix
  # seconds; %s and %Q read the seconds and milliseconds since the epoch.
  def test_a_format_reads_integers_as_their_digits
    f = "%Y%m%d"
    assert_equal ["2000-01-01", "2024-02-29"],
                 CArray.time(CA_INT64([20000101, 20240229]), format: f, unit: :D).to_a.map(&:to_s)
    x = CA_INT32([20000101, 20240229])
    x[1] = UNDEF
    assert_equal ["2000-01-01", UNDEF], CArray.time(x, format: f, unit: :D).to_a.map { |v| UNDEF.equal?(v) ? v : v.to_s }
    assert_equal ["2000-01-01"], CArray.time(20000101, format: f, unit: :D).to_a.map(&:to_s)
    assert_equal ["2000-01-01"], CArray.time([20000101], format: f, unit: :D).to_a.map(&:to_s)
    # Without a format an Integer counts ticks of the unit: days with unit: :D,
    # seconds with no unit.
    assert_equal ["1970-01-02"], CArray.time(CA_INT64([1]), unit: :D).to_a.map(&:to_s)
    assert_equal ["1970-01-02T00:00:00Z"], CArray.time(CA_INT64([86400])).to_a.map(&:to_s)
    assert_equal ["2023-11-14T22:13:20Z"],
                 CArray.time(CA_INT64([1700000000]), format: "%s", unit: :s).to_a.map(&:to_s)
    assert_equal ["2023-11-14T22:13:20.123Z"],
                 CArray.time("1700000000123", format: "%Q", unit: :ms).to_a.map(&:to_s)
  end

  # Without unit:, the values are read in the finest unit they show, so a
  # fraction of a second is kept rather than cut to :s.
  def test_the_unit_defaults_to_the_finest_the_values_show
    unit = ->(*a, **k) { CArray.time(*a, **k).unit.to_s }
    assert_equal "D", unit.(%w[2013-08-01 2013-08-02])
    assert_equal "s", unit.(["2013-08-01 10:30", "2013-08-02"])
    assert_equal "ms", unit.(%w[2013-08-01T10:00:00.5])
    assert_equal ["2013-08-01T10:00:00.500Z"], CArray.time(%w[2013-08-01T10:00:00.5]).to_a.map(&:to_s)
    assert_equal "ms", unit.(["Aug 1 2013 10:00:00.25"])
    assert_equal "D", unit.(CA_INT64([20240101]), format: "%Y%m%d")
    assert_equal "ms", unit.(["2024-01-01 10:00:00.123"], format: "%Y-%m-%d %H:%M:%S.%L")
    assert_equal "s", unit.(1700000000)
    assert_equal "ms", unit.(Time.utc(2024, 1, 1, 0, 0, 0.5r))
    assert_equal "D", unit.(Date.new(2024, 1, 1))
    assert_equal "s", unit.([Date.new(2024, 1, 1), "2024-01-01T10:00"])
    assert_equal "h", unit.(%w[2013-08-01], unit: :h)
  end

  # A month beside a day or an hour is read on the fixed unit both reach.
  def test_calendar_and_fixed_elements_take_the_fixed_unit
    m = CArray.time(["2024-03"], unit: :M)[0]
    d = CArray.time(["2024-03-05"], unit: :D)[0]
    h = CArray.time(["2024-03-05 10:00"], unit: :h)[0]
    y = CArray.time(["2024"], unit: :Y)[0]
    show = ->(t) { [t.unit.to_s, t.to_a.map { |v| UNDEF.equal?(v) ? v : v.to_s }] }
    assert_equal ["D", ["2024-03-01", "2024-03-05"]], show.(CArray.time([m, d]))
    assert_equal ["h", ["2024-03-01T00:00:00Z", "2024-03-05T10:00:00Z"]], show.(CArray.time([m, h]))
    assert_equal ["M", ["2024-01", "2024-03"]], show.(CArray.time([y, m]))
    assert_equal ["D", ["2024-03-01", UNDEF, "2024-03-05"]], show.(CArray.time([m, nil, d]))
    assert_equal ["D", ["2024-03-01", "2024-03-05"]], show.(CArray.time(%w[2024-03 2024-03-05]))
    assert_equal ["2024-03-01", "2024-03-05"],
                 CAFrame.from_records([{ "t" => m }, { "t" => d }])["t"].to_a.map(&:to_s)
  end
  def test_an_integer_counts_ticks_of_the_unit
    ts = ->(t) { t.to_a.map(&:to_s) }
    assert_equal ["1970-01-01T00:00:00Z", "1970-01-01T00:10:00Z", "1970-01-01T01:00:00Z"],
                 ts.(CArray.time(CA_INT64([0, 10, 60]), unit: :m))
    assert_equal ts.(CA_INT64([0, 1, 2]).time(unit: "10 minutes")),
                 ts.(CArray.time(CA_INT32([0, 1, 2]), unit: "10 minutes"))
    assert_equal ["1970-01-01T03:00:00Z"], ts.(CArray.time(3, unit: :h))
    assert_equal ["1970-01-03", "2024-01-01"], ts.(CArray.time([2, "2024-01-01"], unit: :D))
    assert_equal ["1970-02"], ts.(CArray.time(CA_INT64([1]), unit: :M))
    a = CA_INT64([1, 2])
    a[1] = UNDEF
    assert_equal ["1970-01-02", UNDEF], CArray.time(a, unit: :D).to_a.map { |v| UNDEF.equal?(v) ? v : v.to_s }
    # no unit: seconds, as before
    assert_equal ["2023-11-14T22:13:20Z"], ts.(CArray.time(1700000000))
  end

  def test_an_integer_instant_elsewhere_is_still_unix_seconds
    assert_equal ["1970-01-01T01:00:00Z", "1970-01-01T02:00:00Z"],
                 CArray.time_series(3600, count: 2, unit: :h).to_a.map(&:to_s)
    assert_equal "#<CATime::Grid hours since 1970-01-01 02:00:00>", CATime::Grid.new(:h, 7200).inspect
  end
end
