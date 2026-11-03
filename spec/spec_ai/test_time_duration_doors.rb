# frozen_string_literal: true
#
# A year's sign in a literal, and the doors a duration or a time takes a value
# by: a String at every comparison, an element where an array is taken, a
# number on the left.

require "test/unit"
require "carray"

class TestTimeDurationDoors < Test::Unit::TestCase
  def seconds (*v)
    CA_INT64(v).timedelta(unit: :s)
  end

  def days (*v)
    CA_INT64(v).time(unit: :D)
  end

  def texts (a)
    a.to_a.map(&:to_s)
  end

  # ---- the sign of a year -----------------------------------------------

  def test_a_negative_year_keeps_its_sign
    t = Time.utc(-500, 6, 1)
    assert_equal(t, CArray.time(["-0500-152"], unit: :D)[0].to_time)
    assert_equal(Time.utc(-500, 12), CArray.time(["-0500-12"], unit: :M)[0].to_time)
    assert_equal(t, CArray.time(["-0500-06-01"], unit: :D)[0].to_time)
    assert_equal(Time.utc(-1, 1, 1), CArray.time(["-0001-001"], unit: :D)[0].to_time)
  end

  def test_a_negative_year_week_date_is_that_date
    d = Date.new(-500, 6, 1, Date::GREGORIAN)
    s = format("%05d-W%02d-%d", d.cwyear, d.cweek, d.cwday)
    assert_equal(Time.utc(-500, 6, 1), CArray.time([s], unit: :D)[0].to_time)
  end

  def test_the_positive_forms_are_unchanged
    assert_equal(Time.utc(2024, 6, 1), CArray.time(["2024-153"], unit: :D)[0].to_time)
    assert_equal(Time.utc(2024, 12), CArray.time(["2024-12"], unit: :M)[0].to_time)
  end

  def test_a_year_below_a_hundred_stays_that_year
    assert_equal(Time.utc(1, 2, 12), CArray.time(["0001-043"], unit: :D)[0].to_time)
    d = Date.new(50, 3, 1, Date::GREGORIAN)
    s = format("%04d-W%02d-%d", d.cwyear, d.cweek, d.cwday)
    assert_equal(Time.utc(50, 3, 1), CArray.time([s], unit: :D)[0].to_time)
  end

  def test_a_day_a_year_does_not_have_is_refused
    assert_raise(ArgumentError) { CArray.time(["-0500-366"], unit: :D) }
  end

  # ---- a String at the comparisons of a duration -------------------------

  def test_a_duration_compares_with_a_string
    t = seconds(90, 30)
    assert_equal([true, false], t.eq("90 seconds").to_a)
    assert_equal([false, true], t.lt("1 minutes").to_a)
    assert_equal([true, false], t.is_in(["90 seconds"]).to_a)
    assert_equal(%w[60s 60s], texts(t.clip("1 minutes", "1 minutes")))
    assert_equal(%w[90s 60s], texts(t.pmax("1 minutes")))
    assert_equal(%w[30s 30s], texts(t.pmin("30 seconds")))
  end

  def test_a_string_finer_than_the_duration_is_not_rounded
    t = seconds(1, 2)
    assert_equal([false, false], t.eq("1500 milliseconds").to_a)
    assert_equal([true, false], t.lt("1500 milliseconds").to_a)
  end

  def test_a_string_is_stored_into_a_duration
    t = seconds(1, 2)
    t[0] = "1 minutes"
    assert_equal(%w[60s 2s], texts(t))
    t.fill("3 seconds")
    assert_equal(%w[3s 3s], texts(t))
    assert_raise(ArgumentError) { t[0] = "soon" }
  end

  def test_a_string_that_is_no_duration_is_refused
    assert_raise(ArgumentError) { seconds(1).eq("soon") }
  end

  # ---- division and a number on the left --------------------------------

  def test_a_duration_array_is_divided_by_one_duration
    t = seconds(90, 30)
    assert_equal([1.5, 0.5], (t / CA_INT64([60]).timedelta(unit: :s)[0]).to_a)
    assert_equal([1.5, 0.5], (t / "1 minutes").to_a)
    assert_equal([1.5, 0.5], t.div(seconds(60)[0]).to_a)
    assert_equal(%w[45s 15s], texts(t / 2))
  end

  def test_a_number_on_the_left_scales
    t = seconds(3, 4)
    assert_equal(texts(t * 2), texts(2 * t))
    assert_equal("6s", (2 * t[0]).to_s)
    assert_kind_of(CATimedelta, 2 * t)
  end

  def test_only_scaling_has_an_answer_on_the_left
    t = seconds(3, 4)
    assert_raise(TypeError) { 2 / t }
    assert_raise(TypeError) { 2 + t }
    assert_raise(TypeError) { 2 - t }
    assert_raise(TypeError) { 2.5 * t }
    assert_raise(TypeError) { 2 / t[0] }
    assert_raise(TypeError) { 2 + t[0] }
    assert_raise(CArray::DataTypeError) { 2 * days(1) }
  end

  def test_plain_arrays_still_coerce_numbers
    assert_equal([2, 4], (2 * CA_INT32([1, 2])).to_a)
  end

  # ---- elements ---------------------------------------------------------

  def test_a_time_element_moves_by_a_string
    e = days(1, 2)[0]
    assert_equal("1970-01-05", (e + "3 days").to_s)
    assert_equal("1969-12-30", (e - "3 days").to_s)
    assert_equal((days(1, 2) + "3 days")[0].to_s, (e + "3 days").to_s)
  end

  def test_a_time_element_subtracts_a_single_time
    e = days(1, 2)[0]
    assert_equal((days(1) - "1970-01-01")[0].to_s, (e - "1970-01-01").to_s)
    assert_equal((days(1) - Time.utc(1970, 1, 1))[0].to_s, (e - Time.utc(1970, 1, 1)).to_s)
    assert_raise(TypeError) { e + 1 }
  end

  def test_a_duration_element_negates
    e = seconds(-3)[0]
    assert_equal("3s", (-e).to_s)
    assert_equal("3s", e.abs.to_s)
    assert_equal("3s", seconds(3)[0].abs.to_s)
  end

  # ---- seconds of an array ----------------------------------------------

  def test_seconds_of_a_duration_array
    t = CA_INT64([3, 1500]).timedelta(unit: :ms)
    t[1] = UNDEF
    assert_equal([Rational(3, 1000), UNDEF], t.to_seconds.to_a)
    t2 = CA_INT64([2]).timedelta(unit: "3 hours")
    assert_equal([t2[0].to_seconds], t2.to_seconds.to_a)
  end

  def test_a_calendar_duration_has_no_exact_seconds
    m = CA_INT64([2]).timedelta(unit: :M)
    assert_raise(ArgumentError) { m.to_seconds }
    assert_equal([m[0].to_seconds_approx.to_f], m.to_seconds_approx.to_a)
  end

  def test_a_signed_year_on_its_own_reads_back
    d = CArray.time(["+12345-06-01", "-0001-03-01", "-12345-01-01", "2024-01-01"], unit: :D)
    y = d.to_unit(:Y)
    text = y.to_a.map(&:to_s)
    assert_equal ["+12345", "-0001", "-12345", "2024"], text
    assert_equal text, CArray.time(text, unit: :Y).to_a.map(&:to_s)
    assert_equal text, CArray.time(text).to_a.map(&:to_s)
    assert_equal ["+10000-01-01"], CArray.time(["+10000"], unit: :D).to_a.map(&:to_s)
  end
end
