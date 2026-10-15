# frozen_string_literal: true
#
# Where a person reads an array's type -- a frame's column list, describe,
# a refusal naming the type -- a Face is named by its name, not by its
# storage, through one part, CArray::Inspector.type_label: face_label for a
# Face (CATime[D], a class name), the data type name for any other array.
# Before, seven places wrote "face? ? class : data_type" by hand, so a time
# column read "CATime" in one place and "CATime[D]" in another.

require "test/unit"
require "carray"
require "carray/frame"

class TestTypeLabel < Test::Unit::TestCase

  def time ; CArray.time(%w[2024-01-01 2024-01-02], unit: :D) ; end

  def test_the_part
    assert_equal "CATime[D]", CArray::Inspector.type_label(time)
    assert_equal "int32", CArray::Inspector.type_label(CA_INT32([1]))
  end

  def test_a_frame_names_a_time_column_one_way
    df = CAFrame.new("t" => time, "v" => CA_INT32([1, 2]))
    assert_match(/t:CATime\[D\]/, df.inspect)
    assert_equal %w[CATime[D] int32], df.describe["type"].to_a
  end

  def test_a_refusal_names_a_face_by_its_label
    df = CAFrame.new("k" => CA_INT32([0, 1]), "t" => time)
    e = assert_raise(CArray::DataTypeError) { df.group_by("k").sum("t") }
    assert_match(/\(CATime\[D\]\) has no sum/, e.message)
  end

end
