require "test/unit"
require "carray"
require "stringio"

# A column name given to a CAFrame verb is a String, and any other name --
# a Symbol above all, which a frame keeps for its options and types -- is
# refused by one part with TypeError "<verb>: a column name is a String".
# The constructor, cast, to_frame, from_csv and the readers' missing: had
# each refused it by hand, two of them with ArgumentError; an axis_name:
# given as a Symbol was taken, leaving the index unreachable by its name.
class TestCAFrameColumnNames < Test::Unit::TestCase

  def assert_refused (message, &block)
    err = assert_raise(TypeError, message) { block.() }
    assert_equal message, err.message
  end

  def test_every_entry_refuses_a_symbol_name_alike
    df = CAFrame.new("a" => CA_INT32([1, 2]), "s" => CA_OBJECT(["x", "y"]))
    assert_refused("CAFrame.new: a column name is a String (got :b); " \
                   "axis_name:, index:, attrs:, types: and on_error: are the options") {
      CAFrame.new("a" => CA_INT32([1, 2]), b: CA_INT32([3, 4]))
    }
    assert_refused("CAFrame.new: axis_name: is a String (got :row)") {
      CAFrame.new({ "a" => CA_INT32([1, 2]) }, axis_name: :row)
    }
    assert_refused("cast: a column name is a String (got :a); " \
                   ":default is the only Symbol key") {
      df.copy.cast(a: :float64)
    }
    assert_refused("to_frame: a column name is a String (got :x)") {
      CA_INT32([[1, 2], [3, 4]]).to_frame(:x, "y")
    }
    assert_refused("from_csv: columns: a column name is a String (got :c)") {
      CAFrame.from_csv(StringIO.new("a,c\n1,2\n"), columns: ["a", :c])
    }
    assert_refused("from_csv: columns: a column name is a String (got :x); " \
                   "given for \"a\"") {
      CAFrame.from_csv(StringIO.new("a,c\n1,2\n"), columns: { "a" => :x })
    }
    assert_refused("from_csv: missing: a column name is a String (got :a); " \
                   ":default is the only Symbol key") {
      CAFrame.from_csv(StringIO.new("a,c\n1,2\n"), missing: { a: "-999" })
    }
    assert_refused("types: a column name is a String (got :a); " \
                   ":default is the only Symbol key") {
      CAFrame.from_csv(StringIO.new("a,c\n1,2\n"), types: { a: :int32 })
    }
    assert_refused("group_by: a column name is a String (got :s)") {
      df.group_by(:s)
    }
  end

  def test_string_names_and_the_default_key_are_taken
    df = CAFrame.new({ "a" => CA_INT32([1, 2]) }, axis_name: "row")
    assert_equal "row", df.axis_name
    assert_equal CA_FLOAT64, df.copy.cast(default: :float64)["a"].data_type
    got = CAFrame.from_csv(StringIO.new("a,c\n-999,2\n"), missing: { default: "-999" })
    assert_equal 1, got["a"].count_masked
  end
end
