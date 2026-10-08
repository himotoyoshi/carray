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

  # A quote inside an unquoted field used to make the reader join the lines
  # after it into one record.
  def test_a_quote_inside_an_unquoted_field_raises
    err = assert_raise(MALFORMED) { read("h\n5\"in\nx\n\"y\n") }
    assert_match(/a quote inside unquoted field 1 in record 2/, err.message)
    assert_raise(MALFORMED) { read("w,h\n5\",6\n7,8\n") }
  end

  def test_a_quote_written_quoted_reads
    df = read("h\n\"5\"\"in\"\nx\n")
    assert_equal ["5\"in", "x"], df["h"].to_a
  end

  def test_a_space_before_an_opening_quote
    assert_raise(MALFORMED) { read(%Q{a,b\n "x",2\n}) }
    df = read(%Q{a,b\n "x" , 2\n}, strip: true)
    assert_equal [["x"], ["2"]], df.variables.map(&:to_a)
  end

  def test_records_and_line_breaks
    df = read("a,b\r\n\"x\r\ny\",2\r\n3,\"\"\r\n")
    assert_equal ["x\r\ny", "3"], df["a"].to_a
    assert_equal ["2", ""], df["b"].to_a
    df = read("a,b\n\"q\",x\ry\n")
    assert_equal ["x\ry"], df["b"].to_a
    df = read("a,b\n\"x\",2")
    assert_equal [["x"], ["2"]], df.variables.map(&:to_a)
  end

  def test_an_unterminated_quoted_field_names_its_record
    err = assert_raise(MALFORMED) { read("a\n1\n\"open\nmore\n") }
    assert_match(/record 3/, err.message)
  end

  # A field of many lines used to be re-counted at every line.
  def test_a_field_of_many_lines_reads_in_linear_time
    times = [20_000, 80_000].map do |n|
      text = "a\n\"" + ("x\n" * n) + "\"\n"
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      df = read(text)
      assert_equal n * 2, df["a"][0].size
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end
    assert_operator times[1], :<, times[0] * 10      # 4x the lines; quadratic was 16x
  end

  def test_a_second_body_keeps_the_rows
    df = read("a\n1\n2\n") { header; body; body }
    assert_equal ["1", "2"], df["a"].to_a
  end

  def test_a_parser_keeps_its_rows
    rows = [["1"], ["2", "3"]]
    df = CAFrame.from_csv(nil, parser: ->(_) { [["a", "b"], rows] })
    assert_equal [["1"], ["2", "3"]], rows
    assert_equal ["1", "2"], df["a"].to_a
    assert_equal [UNDEF, "3"], df["b"].to_a
  end

  def test_bad_options_raise_argument_errors
    assert_raise(ArgumentError) { read("a\n", sep: "") }
    assert_raise(ArgumentError) { read("a\n", quote: "''") }
    assert_raise(ArgumentError) { read("a\n", sep: "\"") }
    assert_raise(ArgumentError) { read("a\n1\n") { skip "x"; body } }
  end

  def test_a_separator_in_another_encoding_says_how_to_read
    io = StringIO.new("a;b\n1;2\n".encode("UTF-16LE"))
    io.set_encoding("UTF-16LE")
    err = assert_raise(Encoding::CompatibilityError) { CAFrame.from_csv(io) }
    assert_match(/transcoded to UTF-8/, err.message)
  end
end
