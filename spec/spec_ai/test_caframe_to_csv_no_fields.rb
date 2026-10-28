# frozen_string_literal: true

require "test/unit"
require "carray"

# to_csv refuses a frame with rows and no field to write: lines with no
# fields read back as blank lines, and the rows would be lost.
class TestCAFrameToCsvNoFields < Test::Unit::TestCase
  def test_index_only_frame
    df = CAFrame.new({}, index: CA_INT64([1, 2, 3]))
    assert_equal "row\n1\n2\n3\n", df.to_csv
    assert_raise(ArgumentError) { df.to_csv(index: false) }
  end

  def test_a_frame_without_rows_is_still_written
    assert_equal "\n", CAFrame.new({}).to_csv
    assert_equal "\n", CAFrame.new({}, index: CA_INT64([1]))[0...0].to_csv(index: false)
  end
end
