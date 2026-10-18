# frozen_string_literal: true
#
# Ruby values a frame turns into a column are typed by one rule, wherever
# the frame takes them (CAFrame.build_record_column): Integers an int64
# column, numbers a float64 one, arrays of one shape an N-D column (numeric
# CArray cells in the data type they have in common), anything
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
    [[1, nil], [3, 4]]   => [:int64, [2, 2]],
    [[1, UNDEF], [3, 4]] => [:int64, [2, 2]],
    [CA_INT32([1, 2]).tap { |c| c[1] = UNDEF }, CA_INT32([3, 4])] => [:int32, [2, 2]],
    [CA_FLOAT32([1, 2]), CA_FLOAT32([3, 4])] => [:float32, [2, 2]],
    [CA_INT8([1, 2]), CA_FLOAT32([3, 4])]    => [:float32, [2, 2]],
    [CA_INT8([1, 2]), nil]                   => [:int8, [2, 2]],
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

  # A common data type that would change a cell's value is not used:
  # the column is typed by its values, as Ruby values are.
  CELLS_A_COMMON_TYPE_WOULD_CHANGE = {
    [CA_INT64([-5]), CA_UINT64([3])]      => [:int64, [[-5], [3]]],
    [CA_UINT8([200]), CA_INT8([-3])]      => [:int64, [[200], [-3]]],
    [CA_INT32([-7]), CA_UINT32([4e9])]    => [:int64, [[-7], [4_000_000_000]]],
    [CA_UINT64([2**63]), CA_INT8([-1])]   => [:object, [[2**63], [-1]]],
  }.freeze

  def test_a_common_type_that_changes_a_value_is_not_used
    CELLS_A_COMMON_TYPE_WOULD_CHANGE.each do |v, (type, values)|
      ENTRIES.each do |entry, make|
        col = make.(v)
        assert_equal type, col.data_type, "#{entry} #{v.inspect}"
        assert_equal values, col.to_a, "#{entry} #{v.inspect}"
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
