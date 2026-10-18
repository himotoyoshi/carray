# frozen_string_literal: true
#
# A time / duration element copies, marshals and compares with a Date.

require "test/unit"
require "date"
require "carray"

class TestTimeElementCopy < Test::Unit::TestCase

  def test_dup_clone_and_marshal_keep_value_and_unit
    s  = CArray.time("2024-01-01T05", unit: "3 hours")[0]
    td = CA_INT64([5]).timedelta(unit: "10 minutes")[0]
    [s, td].each do |e|
      [e.dup, e.clone, Marshal.load(Marshal.dump(e))].each do |c|
        assert_equal e.class, c.class
        assert c.eql?(e)
        assert_equal e, c
        assert_equal e.to_s, c.to_s
      end
    end
  end

  def test_compare_with_a_date
    d = CArray.time("2024-01-01", unit: :D)[0]
    assert_equal d, Date.new(2024, 1, 1)
    assert_equal(-1, d <=> Date.new(2024, 1, 2))
    assert_equal CArray.time("2024-01", unit: :M)[0], Date.new(2024, 1, 1)
    assert CArray.time("2024-01-01T12", unit: :h)[0] > Date.new(2024, 1, 1)
    assert_equal d, DateTime.new(2024, 1, 1)
  end

end
