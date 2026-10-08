require "test/unit"
require "stringio"
require "carray"

# CSV input that used to lose data without a word.
class TestCAFrameCSVMalformed < Test::Unit::TestCase
  MALFORMED = CAFrame::CSVParser::MalformedCSV

  def read(text, **opts, &dsl)
    CAFrame.from_csv(StringIO.new(text), **opts, &dsl)
  end

  # Text after a closing quote used to end the record and drop every later
  # field.
  def test_text_after_a_closing_quote_raises
    err = assert_raise(MALFORMED) { read("a,b,c\n\"ab\"cd,2,3\n") }
    assert_match(/"cd,2,3" after the closing quote of field 1 in record 2/, err.message)
  end

  def test_a_space_after_a_closing_quote_raises
    assert_raise(MALFORMED) { read("a,b\n\"x\" ,2\n") }
  end

  def test_strip_lets_spaces_after_a_closing_quote_through
    df = read("a,b\n\"x\"  ,2\n\"y\"\t\n", strip: true)
    assert_equal ["x", "y"], df["a"].to_a
    assert_equal ["2", UNDEF], df["b"].to_a
  end

  def test_a_quoted_field_still_ends_at_the_separator_or_the_record
    df = read("a,b\n\"x,1\",\"y\"\"z\"\n\"\",3\n")
    assert_equal ["x,1", ""], df["a"].to_a
    assert_equal ["y\"z", "3"], df["b"].to_a
  end

  # A multi-character separator used to be read as a set of characters on a
  # record with a quote in it.
  def test_a_multi_character_separator_with_a_quote_in_the_record
    df = read("a::b\nx:y::\"2\"\n\"p::q\"::r:s\n", sep: "::")
    assert_equal ["x:y", "p::q"], df["a"].to_a
    assert_equal ["2", "r:s"], df["b"].to_a
  end

  # Values that hold part of the separator, at either end or alone; a value
  # ending in part of it has to be quoted on the way out.
  def test_a_multi_character_separator_round_trips
    vals = ["a:b", ":", "::", "a:", ":a", "a::", "q\"x", "x"]
    df = CAFrame.new("s" => CA_OBJECT(vals), "t" => CA_OBJECT(vals.reverse))
    ["::", ":::", "ab|"].each do |sep|
      back = read(df.to_csv(sep: sep), sep: sep)
      assert_equal vals, back["s"].to_a, sep
      assert_equal vals.reverse, back["t"].to_a, sep
    end
  end

  # A repeated header name used to keep only the last of its columns.
  def test_a_repeated_header_name_raises
    err = assert_raise(ArgumentError) { read("a,b,a\n1,2,3\n") }
    assert_match(/"a" more than once/, err.message)
  end

  def test_two_empty_header_names_raise
    assert_raise(ArgumentError) { read("a,,\n1,2,3\n") }
  end

  def test_column_names_rename_a_repeated_header
    df = read("a,a\n1,2\n") { skip 1; column_names "a", "a2"; body }
    assert_equal [["1"], ["2"]], df.variables.map(&:to_a)
  end

  def test_repeated_column_names_raise
    assert_raise(ArgumentError) { read("1,2\n") { column_names "x", "x"; body } }
  end
end
