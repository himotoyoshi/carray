# frozen_string_literal: true
#
# Ruby values a frame turns into a column are typed by one rule, wherever
# the frame takes them (CAFrame.build_record_column): Integers an int64
# column, numbers a float64 one, arrays of one shape an N-D column, anything
# else object; nil and UNDEF are a missing cell; an Integer an int64 cannot
# hold keeps the column object.  A CArray is kept as it is.
#
# Before, CAFrame.new and df[name]= took a Ruby Array through Array#to_ca,
# always object, while from_records and a group's block values were typed;
# and from_records read UNDEF as a value and raised RangeError on an Integer
# past int64.

require "test/unit"
require "carray"
require "carray/frame"

class TestFrameValueTyping < Test::Unit::TestCase

  ENTRIES = {
    "CAFrame.new"  => ->(v) { CAFrame.new("x" => v)["x"] },
    "df[]="        => ->(v) { df = CAFrame.new("y" => CArray.int32(v.size)); df["x"] = v; df["x"] },
    "from_records" => ->(v) { CAFrame.from_records(v.map { |x| { "x" => x } })["x"] },
    "group table"  => ->(v) {
      df = CAFrame.new("k" => CArray.int32(v.size).seq)
      i = -1
      df.group_by("k").table { |_| { "x" => v[i += 1] } }["x"]
    },
  }.freeze

  VALUES = {
    [1, 2]           => [:int64, [2]],
    [1, 2.5]         => [:float64, [2]],
    [1, nil]         => [:int64, [2]],
    [1, UNDEF]       => [:int64, [2]],
    [1.5, nil]       => [:float64, [2]],
    %w[a b]          => [:object, [2]],
    [true, false]    => [:object, [2]],
    [[1, 2], [3, 4]] => [:int64, [2, 2]],
    [2**70, 1]       => [:object, [2]],
  }.freeze

  def test_every_entry_types_the_values_the_same_way
    VALUES.each do |v, (type, shape)|
      ENTRIES.each do |entry, make|
        col = make.(v)
        assert_equal type, col.data_type, "#{entry} #{v.inspect}"
        assert_equal shape, col.shape, "#{entry} #{v.inspect}"
      end
    end
  end

  def test_nil_and_undef_are_a_missing_cell
    ENTRIES.each do |entry, make|
      assert_equal [1, UNDEF], make.([1, nil]).to_a, entry
      assert_equal [1, UNDEF], make.([1, UNDEF]).to_a, entry
    end
  end

  def test_a_carray_is_kept_as_it_is
    col = CA_OBJECT([1, 2])
    assert_same col, CAFrame.new("x" => col)["x"]
  end

end
