require "test/unit"
require "stringio"
require "tmpdir"
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
    assert_equal %q{line 2: text "cd,2,3" after the closing quote of field 1}, err.message
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
    df = read("a,a\n1,2\n") { |r| r.skip 1; r.column_names "a", "a2"; r.data }
    assert_equal [["1"], ["2"]], df.columns.map(&:to_a)
  end

  def test_repeated_column_names_raise
    assert_raise(ArgumentError) { read("1,2\n") { |r| r.column_names "x", "x"; r.data } }
  end

  # A quote inside an unquoted field used to make the reader join the lines
  # after it into one record.
  def test_a_quote_inside_an_unquoted_field_raises
    err = assert_raise(MALFORMED) { read("h\n5\"in\nx\n\"y\n") }
    assert_match(/\Aline 2: a quote inside unquoted field 1 /, err.message)
    assert_raise(MALFORMED) { read("w,h\n5\",6\n7,8\n") }
  end

  def test_a_quote_written_quoted_reads
    df = read("h\n\"5\"\"in\"\nx\n")
    assert_equal ["5\"in", "x"], df["h"].to_a
  end

  def test_a_space_before_an_opening_quote
    assert_raise(MALFORMED) { read(%Q{a,b\n "x",2\n}) }
    df = read(%Q{a,b\n "x" , 2\n}, strip: true)
    assert_equal [["x"], ["2"]], df.columns.map(&:to_a)
  end

  # A one-line record with quotes is read by splitting at the separator;
  # these are the shapes that path has to agree with the scanner on.
  def test_quoted_fields_on_one_line
    df = read(%Q{a,b,c,d\n"x,y",""," ""q"" ",\n"",p,"a,,b","1"\n})
    assert_equal ["x,y", ""], df["a"].to_a
    assert_equal ["", "p"], df["b"].to_a
    assert_equal [" \"q\" ", "a,,b"], df["c"].to_a
    assert_equal [UNDEF, "1"], df["d"].to_a
    df = read(%Q{a::b\n"x::y"::"z"\n}, sep: "::")
    assert_equal [["x::y"], ["z"]], df.columns.map(&:to_a)
    assert_raise(MALFORMED) { read(%Q{a,b\n"x,y"z,1\n}) }
    assert_raise(MALFORMED) { read(%Q{a,b\nx"y,1\n}) }
  end

  def test_records_and_line_breaks
    df = read("a,b\r\n\"x\r\ny\",2\r\n3,\"\"\r\n")
    assert_equal ["x\r\ny", "3"], df["a"].to_a
    assert_equal ["2", ""], df["b"].to_a
    df = read("a,b\n\"q\",x\ry\n")
    assert_equal ["x\ry"], df["b"].to_a
    df = read("a,b\n\"x\",2")
    assert_equal [["x"], ["2"]], df.columns.map(&:to_a)
  end

  def test_an_unterminated_quoted_field_names_the_line_it_opens_on
    err = assert_raise(MALFORMED) { read("a\n1\n\"open\nmore\n") }
    assert_equal "line 3: quoted field 1 opened here is never closed", err.message
  end

  # The line is the file's, which an editor jumps to: a quoted field of
  # several lines before it, or a skip, makes it differ from the record.
  def test_an_error_names_the_line_of_the_file
    rows = (1..3000).map { |i| "#{i},\"x\ny\"\n" }.join
    [1 << 22, 7].each do |n|
      with_chunk_bytes(n) do
        err = assert_raise(MALFORMED) { read("a,b\n" + rows + "9,\"ab\ncd\"e\n") }
        assert_equal [6003, 3002], [err.lineno, err.record]
        assert_equal %q{line 6003: text "e" after the closing quote of field 2 (record 3002)}, err.message
      end
    end
    err = assert_raise(MALFORMED) { read("# x\n# y\na,b\n1,2\n1,2\"\n") { |r| r.skip 2; r.header; r.data } }
    assert_equal [5, 3], [err.lineno, err.record]
  end

  # A record longer than the header used to raise an ArgumentError counting
  # data rows, not lines.
  def test_a_record_with_too_many_fields_names_its_line
    err = assert_raise(MALFORMED) { read("a,b\r\n1,2\r\n3,4,5\r\n") }
    assert_equal "line 3: 3 fields, but there are 2 columns", err.message
    err = assert_raise(MALFORMED) { read("1,2\n\n3,4,5\n") { |r| r.column_names "a", "b"; r.data } }
    assert_equal 3, err.lineno
  end

  def test_an_error_names_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "obs.csv")
      File.write(path, "a,b\n1,2\n3,x\"y\n")
      err = assert_raise(MALFORMED) { CAFrame.from_csv(path) }
      assert_equal path, err.path
      assert_match(/\A#{Regexp.escape(path)}:3: a quote inside unquoted field 2 /, err.message)
      err = assert_raise(MALFORMED) { File.open(path) { |io| CAFrame.from_csv(io) } }
      assert_match(/\A#{Regexp.escape(path)}:3: /, err.message)
    end
  end

  def with_chunk_bytes(n)
    old = CAFrame::CSVReader::CHUNK_BYTES
    CAFrame::CSVReader.send(:remove_const, :CHUNK_BYTES)
    CAFrame::CSVReader.const_set(:CHUNK_BYTES, n)
    yield
  ensure
    CAFrame::CSVReader.send(:remove_const, :CHUNK_BYTES)
    CAFrame::CSVReader.const_set(:CHUNK_BYTES, old)
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
    df = read("a\n1\n2\n") { |r| r.header; r.data; r.data }
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
    assert_raise(ArgumentError) { read("a\n1\n") { |r| r.skip "x"; r.data } }
  end

  # A line of only spaces used to be a short row in a file of several
  # columns; it is a blank line there, as an empty one is.
  def test_a_line_of_spaces_is_blank_in_a_file_of_several_columns
    df = read("a,b\n1,2\n  \n\t\n3,4\n")
    assert_equal [["1", "3"], ["2", "4"]], df.columns.map(&:to_a)
  end

  def test_a_line_of_separators_is_a_row
    df = read("a\tb\n1\t2\n\t\n", sep: "\t")
    assert_equal [["1", UNDEF], ["2", UNDEF]], df.columns.map(&:to_a)
  end

  def test_spaces_are_a_value_in_a_file_of_one_column
    assert_equal ["1", "  ", "3"], read("a\n1\n  \n3\n")["a"].to_a
    assert_equal ["1", UNDEF, "3"], read("a\n1\n  \n3\n", strip: true)["a"].to_a
  end

  # Without a header the column count is known only after the body; blank
  # lines used to be skipped even in a file of one column.
  def test_blank_lines_without_a_header
    df = read("a\n\nc\n") { |r| r.data }
    assert_equal ["a", UNDEF, "c"], df["c0"].to_a
    df = read("a,b\n\nc,d\n  \n") { |r| r.data }
    assert_equal [["a", "c"], ["b", "d"]], df.columns.map(&:to_a)
  end

  # A blank last line of a one-column file is a masked last row, since that
  # is how to_csv writes one; the two cannot be told apart.
  def test_a_blank_last_line_of_a_one_column_file_is_a_row
    df = CAFrame.new("s" => CA_OBJECT(["a", "b", "x"]))
    df["s"][2] = UNDEF
    assert_equal "s\na\nb\n\n", df.to_csv
    assert_equal ["a", "b", UNDEF], read("s\na\nb\n\n")["s"].to_a
  end

  # A header of one blank name would be a blank line the reader skips, so
  # to_csv quotes a value of spaces and tabs.
  def test_a_blank_name_of_a_one_column_file_round_trips
    [" ", "\t", "  \t"].each do |name|
      df = CAFrame.new(name => CA_INT32([1, 2, 3]))
      back = read(df.to_csv)
      assert_equal [name], back.column_names, name.inspect
      assert_equal %w[1 2 3], back[name].to_a
    end
  end

  def test_a_blank_value_round_trips_under_strip
    df = CAFrame.new("a" => CA_OBJECT(["x", " ", "\t"]))
    assert_equal ["x", " ", "\t"], read(df.to_csv)["a"].to_a
    assert_equal ["x", " ", "\t"], read(df.to_csv, strip: true)["a"].to_a
  end

  def test_a_separator_in_another_encoding_says_how_to_read
    io = StringIO.new("a;b\n1;2\n".encode("UTF-16LE"))
    io.set_encoding("UTF-16LE")
    err = assert_raise(Encoding::CompatibilityError) { CAFrame.from_csv(io) }
    assert_match(/transcoded to UTF-8/, err.message)
  end

  # A frame without columns or index writes an empty header line; reading
  # it, or an empty input, gives that frame back.
  def test_an_input_with_no_record_is_a_frame_without_columns
    ["", "\n", "\n\n"].each do |text|
      df = read(text)
      assert_equal [0, []], [df.nrow, df.column_names], text.inspect
    end
    df = read(CAFrame.new({}).to_csv)
    assert_equal [0, []], [df.nrow, df.column_names]
  end

  # Past skipped lines, or for a named secondary header, a missing header is
  # still an error.
  def test_a_header_after_skipped_lines_still_has_to_be_there
    assert_raise(MALFORMED) { read("x\n", header: 2) }
    assert_raise(MALFORMED) { read("") { |r| r.skip 1; r.header; r.data } }
    assert_raise(MALFORMED) { read("") { |r| r.header("units"); r.data } }
  end
end
