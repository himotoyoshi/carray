require "test/unit"
require "stringio"
require "carray"

# from_csv's header: / data: / column_names:, and the reading block that
# takes the reader as its parameter.
class TestCAFrameCSVLayout < Test::Unit::TestCase
  MALFORMED = CAFrame::CSVParser::MalformedCSV

  TEXT = "Observations\n\nstation,temp\nname,degC\nTokyo,1\nOsaka,2\nNagoya,3\nSendai,4\n"

  def read(text, **opts, &block)
    CAFrame.from_csv(StringIO.new(text), **opts, &block)
  end

  def cells(df)
    [df.column_names, *df.columns.map(&:to_a)]
  end

  # The same input read by the Ruby tokenizer alone.
  def in_ruby
    c_split = CArray.method(:__csv_read_body_as_string_cells__)
    CArray.define_singleton_method(:__csv_read_body_as_string_cells__) { |*| nil }
    yield
  ensure
    CArray.define_singleton_method(:__csv_read_body_as_string_cells__, c_split)
  end

  def test_header_and_data_lines
    df = read(TEXT, header: 2, data: 4)
    assert_equal [%w[station temp], %w[Tokyo Osaka Nagoya Sendai], %w[1 2 3 4]], cells(df)
    df = read(TEXT, header: 2, data: 4..5)
    assert_equal %w[Tokyo Osaka], df["station"].to_a
    assert_equal cells(df), cells(read(TEXT, header: 2, data: 4...6))
    assert_equal %w[Nagoya Sendai], read(TEXT, header: 2, data: 6..)["station"].to_a
    assert_equal %w[name Tokyo], read(TEXT, header: 2, data: ..4)["station"].to_a
  end

  # An error names the line from 1, as an editor does; data: indexes it
  # from 0, as File.readlines does.
  def test_an_error_line_and_the_index
    text = "a,b\n1,2\n3,x\"\n"
    err = assert_raise(MALFORMED) { read(text) }
    assert_equal 3, err.lineno
    assert_equal "3,x\"\n", text.lines[err.lineno - 1]
    assert_equal %w[1], read(text, data: ...(err.lineno - 1))["a"].to_a
  end

  def test_the_defaults
    assert_equal cells(read("a,b\n1,2\n")), cells(read("a,b\n1,2\n", header: 0, data: 1))
    df = read("1,2\n3,4\n", column_names: %w[x y])
    assert_equal [%w[x y], %w[1 3], %w[2 4]], cells(df)
    df = read("a,b\n1,2\n", header: 0, column_names: %w[x y])
    assert_equal [%w[x y], %w[1], %w[2]], cells(df)
    df = read("1,2\n3,4\n", header: false)
    assert_equal [%w[c0 c1], %w[1 3], %w[2 4]], cells(df)
  end

  def test_the_same_as_the_block
    blocked = read(TEXT) { |r| r.skip 2; r.header; r.skip 1; r.data }
    assert_equal cells(blocked), cells(read(TEXT, header: 2, data: 4))
    assert_equal cells(blocked), cells(read(TEXT) { it.skip 2; it.header; it.skip 1; it.data })
  end

  # A record that starts in the range is read whole, and a blank line at its
  # end does not let the record after it in.
  def test_a_range_ends_at_a_record_start
    text = "a,b\n1,\"x\ny\"\n2,z\n\n3,w\n"
    [false, true].each do |ruby|
      run = -> { cells(read(text, data: 1..1)) }
      got = ruby ? in_ruby(&run) : run.()
      assert_equal [%w[a b], %w[1], ["x\ny"]], got
      run = -> { cells(read(text, data: 1..4)) }
      got = ruby ? in_ruby(&run) : run.()
      assert_equal [%w[a b], %w[1 2], ["x\ny", "z"]], got
    end
  end

  # Lines past the range are not read, so a malformed one there is not seen;
  # one inside it is reported on its own line.
  def test_errors_within_a_range
    text = "a,b\n1,2\n3,4\n5,\"6\n"
    assert_equal %w[1 3], read(text, data: 1..2)["a"].to_a
    err = assert_raise(MALFORMED) { read(text, data: 1..3) }
    assert_equal 4, err.lineno
  end

  def test_bad_settings
    assert_raise(ArgumentError) { read(TEXT, header: -1) }
    assert_raise(ArgumentError) { read(TEXT, header: "3") }
    assert_raise(ArgumentError) { read(TEXT, data: -1) }
    assert_raise(ArgumentError) { read(TEXT, data: "2:101") }
    assert_raise(ArgumentError) { read(TEXT, data: 5..4) }
    err = assert_raise(ArgumentError) { read(TEXT, header: 2, data: 2) }
    assert_equal "from_csv: data: 2 does not come after header: 2", err.message
    err = assert_raise(ArgumentError) { read(TEXT, header: 2) { |r| r.data } }
    assert_match(/header: or a reading block, not both/, err.message)
  end

  # The block is given the reader: a local variable named after a verb would
  # otherwise stand in for it without a word.
  def test_a_block_without_the_reader_raises
    err = assert_raise(ArgumentError) { read(TEXT) { data } }
    assert_match(/\{ \|r\| r\.skip 2; r\.header; r\.data \}/, err.message)
  end

  # A name too many went to an empty column, a name too few left a column
  # that raised as too long only on the rows after it.
  def test_column_names_have_to_match_the_columns
    [false, true].each do |ruby|
      check = lambda do
        err = assert_raise(ArgumentError) { read("1,2\n3,4\n", column_names: %w[a b c]) }
        assert_equal "from_csv: column_names: gives 3 names for the 2 columns of line 1", err.message
        err = assert_raise(ArgumentError) { read("\n\n1,2,3\n", column_names: %w[a b]) }
        assert_match(/2 names for the 3 columns of line 3/, err.message)
        err = assert_raise(ArgumentError) { read("x,y\n1,2\n", header: 0, column_names: %w[a]) }
        assert_match(/1 name for the 2 columns of line 1/, err.message)
        err = assert_raise(ArgumentError) { read("#\n1,2\n") { |r| r.skip 1; r.column_names "a"; r.data } }
        assert_match(/of line 2/, err.message)
        assert_equal [%w[a], [UNDEF, "1", UNDEF, "2"]], cells(read("\n1\n\n2\n", column_names: %w[a]))
        assert_equal [%w[a b], [], []], cells(read("", column_names: %w[a b]))
      end
      ruby ? in_ruby(&check) : check.()
    end
  end

  def test_columns_select_by_name_and_index
    wide = "a,b,c,d\n1,2,3,4\n5,6,7,8\n"
    [false, true].each do |ruby|
      check = lambda do
        assert_equal [%w[c a], %w[3 7], %w[1 5]], cells(read(wide, columns: %w[c a]))
        assert_equal [%w[b c d], %w[2 6], %w[3 7], %w[4 8]], cells(read(wide, columns: 1..))
        assert_equal [%w[d a], %w[4 8], %w[1 5]], cells(read(wide, columns: [3, "a"]))
        assert_equal [%w[c1 c3], %w[2 6], %w[4 8]], cells(read("1,2,3,4\n5,6,7,8\n", header: false, columns: [1, 3]))
        assert_equal [%w[y], %w[2 6]], cells(read("1,2,3,4\n5,6,7,8\n", column_names: %w[w y x z], columns: %w[y]))
        df = read(wide) { |r| r.header; r.columns "d"; r.data }
        assert_equal [%w[d], %w[4 8]], cells(df)
        # A short row reaches a selected column as a missing cell.
        assert_equal [%w[d], [UNDEF, "8"]], cells(read("a,b,c,d\n1,2\n5,6,7,8\n", columns: %w[d]))
      end
      ruby ? in_ruby(&check) : check.()
    end
  end

  def test_columns_are_checked
    wide = "a,b,c\n1,2,3\n"
    err = assert_raise(KeyError) { read(wide, columns: %w[a x]) }
    assert_equal 'from_csv: columns: names no column "x"', err.message
    err = assert_raise(ArgumentError) { read(wide, columns: [0, 3]) }
    assert_equal "from_csv: columns: 3 is past the 3 columns of the file", err.message
    assert_raise(ArgumentError) { read(wide, columns: [0, "a"]) }
    assert_raise(ArgumentError) { read(wide, columns: []) }
    assert_raise(ArgumentError) { read(wide, columns: [-1]) }
    assert_raise(KeyError) { read(wide, columns: %w[a], types: { "b" => :int32 }) }
    assert_equal %w[a], read(wide, columns: %w[a], types: { "a" => :int32 }).column_names
    assert_equal [%w[c a], [3], [1]], cells(read(wide, columns: %w[c a], types: { "a" => :int32, "c" => :int32 }))
  end

  def test_a_header_past_the_end
    err = assert_raise(MALFORMED) { read("a\n1\n", header: 4) }
    assert_match(/header expected but input ended/, err.message)
  end
end
