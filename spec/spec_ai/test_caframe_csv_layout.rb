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
    [df.variable_names, *df.variables.map(&:to_a)]
  end

  # The same input read by the Ruby tokenizer alone.
  def in_ruby
    c_split = CArray.method(:__csv_split__)
    CArray.define_singleton_method(:__csv_split__) { |*| nil }
    yield
  ensure
    CArray.define_singleton_method(:__csv_split__, c_split)
  end

  def test_header_and_data_lines
    df = read(TEXT, header: 3, data: 5)
    assert_equal [%w[station temp], %w[Tokyo Osaka Nagoya Sendai], %w[1 2 3 4]], cells(df)
    df = read(TEXT, header: 3, data: "5:6")
    assert_equal %w[Tokyo Osaka], df["station"].to_a
    assert_equal cells(df), cells(read(TEXT, header: 3, data: 5..6))
    assert_equal cells(df), cells(read(TEXT, header: 3, data: 5...7))
    assert_equal %w[Tokyo Osaka Nagoya Sendai], read(TEXT, header: 3, data: "5:")["station"].to_a
    assert_equal %w[name Tokyo], read(TEXT, header: 3, data: ":5")["station"].to_a
    assert_equal %w[Nagoya Sendai], read(TEXT, header: 3, data: 7..)["station"].to_a
  end

  def test_the_defaults
    assert_equal cells(read("a,b\n1,2\n")), cells(read("a,b\n1,2\n", header: 1, data: 2))
    df = read("1,2\n3,4\n", column_names: %w[x y])
    assert_equal [%w[x y], %w[1 3], %w[2 4]], cells(df)
    df = read("a,b\n1,2\n", header: 1, column_names: %w[x y])
    assert_equal [%w[x y], %w[1], %w[2]], cells(df)
    df = read("1,2\n3,4\n", header: false)
    assert_equal [%w[c0 c1], %w[1 3], %w[2 4]], cells(df)
  end

  def test_the_same_as_the_block
    blocked = read(TEXT) { |r| r.skip 2; r.header; r.skip 1; r.data }
    assert_equal cells(blocked), cells(read(TEXT, header: 3, data: 5))
    assert_equal cells(blocked), cells(read(TEXT) { it.skip 2; it.header; it.skip 1; it.data })
  end

  # A record that starts in the range is read whole, and a blank line at its
  # end does not let the record after it in.
  def test_a_range_ends_at_a_record_start
    text = "a,b\n1,\"x\ny\"\n2,z\n\n3,w\n"
    [false, true].each do |ruby|
      run = -> { cells(read(text, data: "2:2")) }
      got = ruby ? in_ruby(&run) : run.()
      assert_equal [%w[a b], %w[1], ["x\ny"]], got
      run = -> { cells(read(text, data: "2:5")) }
      got = ruby ? in_ruby(&run) : run.()
      assert_equal [%w[a b], %w[1 2], ["x\ny", "z"]], got
    end
  end

  # Lines past the range are not read, so a malformed one there is not seen;
  # one inside it is reported on its own line.
  def test_errors_within_a_range
    text = "a,b\n1,2\n3,4\n5,\"6\n"
    assert_equal %w[1 3], read(text, data: "2:3")["a"].to_a
    err = assert_raise(MALFORMED) { read(text, data: "2:4") }
    assert_equal 4, err.lineno
  end

  def test_bad_settings
    assert_raise(ArgumentError) { read(TEXT, header: 0) }
    assert_raise(ArgumentError) { read(TEXT, header: "3") }
    assert_raise(ArgumentError) { read(TEXT, data: 0) }
    assert_raise(ArgumentError) { read(TEXT, data: "D4:F120") }
    assert_raise(ArgumentError) { read(TEXT, data: "6:5") }
    err = assert_raise(ArgumentError) { read(TEXT, header: 3, data: 3) }
    assert_match(/data: starts on line 3, which is not after the header on line 3/, err.message)
    err = assert_raise(ArgumentError) { read(TEXT, header: 3) { |r| r.data } }
    assert_match(/header: or a reading block, not both/, err.message)
  end

  # The block is given the reader: a local variable named after a verb would
  # otherwise stand in for it without a word.
  def test_a_block_without_the_reader_raises
    err = assert_raise(ArgumentError) { read(TEXT) { data } }
    assert_match(/\{ \|r\| r\.skip 2; r\.header; r\.data \}/, err.message)
  end

  def test_a_header_past_the_end
    err = assert_raise(MALFORMED) { read("a\n1\n", header: 5) }
    assert_match(/header expected but input ended/, err.message)
  end
end
