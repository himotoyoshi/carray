require "test/unit"
require "carray"
require "stringio"

# A column name a user gives can not be empty, at every entry where a name
# comes in; an empty field of a CSV header is named by its position.
class TestFrameEmptyColumnName < Test::Unit::TestCase

  def df
    CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([3, 4]))
  end

  def assert_refused (pattern, &block)
    err = assert_raise(ArgumentError) { block.call }
    assert_match(pattern, err.message)
    assert_match(/can not be empty/, err.message)
  end

  def test_every_entry_refuses_an_empty_name
    assert_refused(/\ACAFrame\.new:/) { CAFrame.new("" => CA_INT32([1])) }
    assert_refused(/\Adf\[name\] =:/) { d = df; d[""] = CA_INT32([5, 6]) }
    assert_refused(/\Arename:/) { df.rename("a" => "") }
    assert_refused(/\Aappend:/) { df.append("", CA_INT32([5, 6])) }
    assert_refused(/\Afrom_records:/) { CAFrame.from_records([{ "" => 1 }]) }
    assert_refused(/\Ato_frame:/) { CArray.int32(2, 2).to_frame("", "x") }
    assert_refused(/\Afrom_csv: columns:/) do
      CAFrame.from_csv(StringIO.new("a,b\n1,2\n"), columns: { "a" => "" }, types: :string)
    end
    assert_refused(/\Afrom_csv: column_names:/) do
      CAFrame.from_csv(StringIO.new("1,2\n"), column_names: ["", "x"], types: :string)
    end
  end

  def test_an_empty_header_field_is_named_by_its_position
    assert_equal %w[c0 b], CAFrame.from_csv(StringIO.new(",b\n1,2\n"), types: :string).column_names
    # by its place in the line, as header: false names it, also when
    # columns: picks it
    text = "a,b,,d\n1,2,3,4\n"
    assert_equal %w[c2 d], CAFrame.from_csv(StringIO.new(text), columns: [2, 3], types: :string).column_names
    assert_equal %w[c2 d], CAFrame.from_csv(StringIO.new(text), columns: [2, 3], types: :infer).column_names
  end

  def test_pivot_names_an_empty_label
    d = CAFrame.new("i" => CA_INT32([1, 1]), "c" => CA_OBJECT(["", "x"]), "v" => CA_INT32([1, 2]))
    err = assert_raise(ArgumentError) { d.pivot(index: "i", columns: "c", values: "v") }
    assert_match(/\Apivot: .*empty string/, err.message)
  end
end
