# frozen_string_literal: true
#
# Date fields that Date._parse / Date._strptime hand back without a month and
# day (day of the year, ISO week, week of the year) name a date, and a clock
# field out of range is refused rather than carried into the next field.

require "test/unit"
require "date"
require "carray"

class TestTimeParseFields < Test::Unit::TestCase

  def day(text, **opts)
    CArray.time(text, unit: :D, **opts)[0].to_s
  end

  def test_day_of_the_year
    assert_equal "2024-01-15", day("2024-015")
    assert_equal "2024-01-15", day("2024015")
    assert_equal "2024-12-31", day("2024-366")
    assert_equal "2024-01-15", day("2024-015", format: "%Y-%j")
    assert_raise(ArgumentError) { day("2023-366") }
    assert_equal %w[2024-01-15], CArray.time(%w[2024-015], unit: :D).to_a.map(&:to_s)
  end

  def test_iso_week
    assert_equal "2024-01-15", day("2024-W03-1")
    assert_equal "2024-01-15", day("2024W031")
    assert_equal "2021-01-03", day("2020-W53-7")
    assert_equal "2024-01-15", day("2024-W03-1", format: "%G-W%V-%u")
    assert_raise(ArgumentError) { day("2021-W53-1") }
  end

  def test_week_of_the_year_agrees_with_date_strptime
    (2019..2026).each do |y|
      (0..53).each do |w|
        (0..6).each do |wd|
          %w[%U %W].each do |f|
            text = "#{y} #{w} #{wd}"
            fmt  = "%Y #{f} %w"
            ref  = begin
              Date.strptime(text, fmt, Date::GREGORIAN)
            rescue ArgumentError
              nil
            end
            if ref && ref.year == y
              assert_equal ref.to_s, day(text, format: fmt), "#{text} #{f}"
            else
              assert_raise(ArgumentError, "#{text} #{f}") { day(text, format: fmt) }
            end
          end
        end
      end
    end
  end

  def test_clock_field_out_of_range
    %w[2024-01-15T10:75 2024-01-15T25:00:00 2024-01-15T10:20:61].each do |text|
      assert_raise(ArgumentError, text) { CArray.time(text, unit: :s) }
    end
    assert_equal "2024-01-16T00:00:00Z", CArray.time("2024-01-15T24:00", unit: :s)[0].to_s
    assert_equal "2024-01-15T10:59:59Z", CArray.time("2024-01-15T10:59:59", unit: :s)[0].to_s
  end

end
