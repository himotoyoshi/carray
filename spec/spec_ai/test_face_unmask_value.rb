# ----------------------------------------------------------------------------
#
#  spec_ai/test_face_unmask_value.rb
#
#  unmask(value) / strip_mask(value) on a Face read the fill value the way a
#  store does: through the Face's write hook.  A Time is an instant, not a
#  count of seconds in the Face's unit; an Element reads as it does in
#  `x[i] = value`, and a value the store refuses is refused here too.
#  CAFrame#fill(name, value) reaches this.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestFaceUnmaskValue < Test::Unit::TestCase

  def masked_days
    x = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D)
    x[1] = UNDEF
    x
  end

  def stored (value)
    y = masked_days
    y[1] = value
    y.to_a.map(&:to_s)
  end

  [
    ["Time",    -> { Time.utc(2024, 1, 9) }],
    ["Element", -> { CArray.time(%w[2024-01-09], unit: :D)[0] }],
  ].each do |name, make|
    define_method("test_unmask_#{name}") do
      x = masked_days
      x.unmask(make.call)
      assert_equal stored(make.call), x.to_a.map(&:to_s)
      assert_equal "2024-01-09", x[1].to_s
    end

    define_method("test_strip_mask_#{name}") do
      x = masked_days
      y = x.strip_mask(make.call)
      assert_kind_of CATime, y
      assert_equal "2024-01-09", y[1].to_s
      assert_equal false, y.has_mask? && y.is_masked.any?
    end
  end

  def test_string_is_refused_as_the_store_refuses_it
    x = masked_days
    assert_raise(ArgumentError) { x[1] = "2024-01-09" }
    assert_raise(ArgumentError) { x.unmask("2024-01-09") }
    assert_raise(ArgumentError) { x.strip_mask("2024-01-09") }
  end

  def test_unmask_hour_unit_with_time
    x = CArray.time(["2024-01-01 00:00", "2024-01-01 01:00"], unit: :h)
    x[1] = UNDEF
    x.unmask(Time.utc(2024, 1, 1, 5))
    assert_equal x[0].class, x[1].class
    assert_equal Time.utc(2024, 1, 1, 5), x[1].to_time
  end

  def test_timedelta_element
    d = CArray.time(%w[2024-01-03 2024-01-05], unit: :D) -
        CArray.time(%w[2024-01-01 2024-01-01], unit: :D)
    fillv = d[0]
    d[1] = UNDEF
    d.unmask(fillv)
    assert_equal d[0].to_s, d[1].to_s
  end

  def test_frame_fill_constant_time
    df = CAFrame.new("x" => masked_days)
    df.fill("x", Time.utc(2024, 1, 9))
    assert_equal %w[2024-01-01 2024-01-09 2024-01-03], df["x"].to_a.map(&:to_s)
  end

end
