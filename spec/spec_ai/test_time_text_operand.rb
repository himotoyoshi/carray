# A time array takes an instant written outside CArray -- Time, Date, String
# -- wherever it takes a CATime: comparison, search, membership, store, and a
# CAFrame time index's at.  Each is read at the precision it carries and then
# reconciled losslessly, so an instant off the array's grid raises instead of
# being floored onto it.

require "test/unit"
require "carray"
require "date"

class TestTimeTextOperand < Test::Unit::TestCase

  def days
    CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"]).to_unit(:D)
  end

  def test_compare_search_membership
    d = days
    assert_equal [false, true, false], d.eq("2024-01-02").to_a
    assert_equal [false, true, false], d.eq(Date.new(2024, 1, 2)).to_a
    assert_equal [false, false, true], (d > "2024-01-02").to_a
    assert_equal 1, d.search("2024-01-02")
    assert_equal [false, true, true], d.is_in(["2024-01-02", Time.utc(2024, 1, 3)]).to_a
    assert_equal [true, false, false], d.is_in([d[0]]).to_a
  end

  def test_off_grid_instant_raises_instead_of_flooring
    d = days
    assert_raise(ArgumentError) { d.eq("2024-01-02 09:00") }
    assert_raise(ArgumentError) { d.eq(Time.utc(2024, 1, 2, 9)) }
    assert_equal [false, true, false], d.eq(Time.utc(2024, 1, 2)).to_a
  end

  def test_precision_and_offset_are_read_from_the_text
    ms = CArray.time(["2024-01-02T09:00:00.5"], unit: :ms)
    assert_equal [true], ms.eq("2024-01-02T09:00:00.5").to_a
    s = CArray.time(["2024-01-02T00:00"])
    assert_equal [true], s.eq("2024-01-02T09:00+09:00").to_a
    assert_raise(ArgumentError) { s.eq("not a time") }
  end

  def test_store
    d = days
    d[0] = "2024-03-04"
    d[1] = Date.new(2024, 3, 5)
    assert_equal ["2024-03-04", "2024-03-05"], [d[0].to_s, d[1].to_s]
    assert_raise(ArgumentError) { d[2] = Time.utc(2024, 3, 6, 9) }
  end

  def test_frame_at
    df = CAFrame.new({ "t" => days, "v" => CA_INT32([1, 2, 3]) }).set_index("t")
    assert_equal 2, df.at("2024-01-02")["v"]
    assert_equal 3, df.at(Date.new(2024, 1, 3))["v"]
    assert_raise(KeyError) { df.at("2024-02-01") }
  end
end
