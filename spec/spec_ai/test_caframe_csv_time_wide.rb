require "test/unit"
require "stringio"
require "carray"

# A column read as time by the caller's word (types: { name => :time },
# cast(name => :time), parse_to_time) reads what to_csv writes for any
# CATime: a date that stops at the month or the year, and a year with a sign
# or more than four digits.  Text that is only being tried as time
# (types: :infer) is read strictly, so "2024" stays a number.
class TestCAFrameCSVTimeWide < Test::Unit::TestCase

  def read (text, **opts)
    CAFrame.from_csv(StringIO.new(text), **opts)
  end

  def round_trip (t)
    df = CAFrame.new("t" => t)
    read(df.to_csv, types: { "t" => :time })["t"]
  end

  def test_month_unit_round_trips
    t = CArray.time(%w[2024-01 2024-03 1969-12], unit: :M)
    back = round_trip(t)
    assert_equal :M, back.unit.base
    assert_equal t.to_a.map(&:to_s), back.to_a.map(&:to_s)
  end

  def test_year_unit_round_trips
    t = CA_INT64([54, -1, -1969, -2000]).time(unit: :Y)
    back = round_trip(t)
    assert_equal :Y, back.unit.base
    assert_equal t.to_a.map(&:to_s), back.to_a.map(&:to_s)
  end

  def test_years_past_four_digits_round_trip
    t = CA_INT64([3_650_000, -800_000, 0]).time(unit: :D)
    back = round_trip(t)
    assert_equal t.to_a.map(&:to_s), back.to_a.map(&:to_s)
    s = CA_INT64([11476 * 365 * 86400, -100_000_000_000]).time(unit: :s)
    assert_equal s.to_a.map(&:to_s), round_trip(s).to_a.map(&:to_s)
  end

  def test_masked_month_cell_round_trips
    t = CArray.time(%w[2024-01 2024-03], unit: :M)
    t[1] = UNDEF
    assert_equal ["2024-01", UNDEF], round_trip(t).to_a.map { |v| UNDEF.equal?(v) ? v : v.to_s }
  end

  def test_month_and_day_cells_read_as_days
    t = read("t\n2024-01\n2024-01-05\n", types: { "t" => :time })["t"]
    assert_equal :D, t.unit.base
    assert_equal %w[2024-01-01 2024-01-05], t.to_a.map(&:to_s)
  end

  def test_cast_and_parse_to_time_read_wide
    df = read("t\n2024-01\n2024-02\n")
    assert_equal %w[2024-01 2024-02], df.cast("t" => :time)["t"].to_a.map(&:to_s)
    assert_equal %w[2024-01 2024-02], read("t\n2024-01\n2024-02\n").parse_to_time("t")["t"].to_a.map(&:to_s)
  end

  def test_infer_reads_strictly
    assert_equal CA_INT64, read("t\n2024\n2025\n", types: :infer)["t"].data_type
    assert_equal({}, read("t\n2024-01\n2024-02\n").infer_types)
    assert_equal({}, read("t\n11963-05-13\n").infer_types)
  end

  def test_not_time_still_reports
    assert_raise(CAFrame::UnreadableColumn) do
      read("t\n2024-13\n", types: { "t" => :time }, on_error: :raise)
    end
    assert_raise(CAFrame::UnreadableColumn) do
      read("t\n202\n", types: { "t" => :time }, on_error: :raise)
    end
  end

end
