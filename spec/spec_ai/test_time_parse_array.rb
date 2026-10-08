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
end
