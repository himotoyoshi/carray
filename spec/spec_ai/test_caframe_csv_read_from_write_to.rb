require "test/unit"
require "carray"
require "stringio"
require "tempfile"

# read_csv / write_csv take a path or an IO; from_csv / to_csv take and give
# CSV text as a String. Each pair takes the same options.
class TestCAFrameCSVReadFromWriteTo < Test::Unit::TestCase

  TEXT = "k,v\n1,a\n,b\n"

  def test_from_csv_reads_the_string_as_csv_text
    df = CAFrame.from_csv(TEXT)
    assert_equal %w[k v], df.column_names
    assert_equal [1, UNDEF], df["k"].to_a
  end

  def test_from_csv_takes_read_csv_options_and_block
    df = CAFrame.from_csv(TEXT, types: :string)
    assert_equal ["1", UNDEF], df["k"].to_a
    df = CAFrame.from_csv("title\n" + TEXT) { |r| r.skip 1; r.header; r.data }
    assert_equal %w[k v], df.column_names
  end

  def test_from_csv_refuses_what_is_not_a_string
    e = assert_raise(TypeError) { CAFrame.from_csv(StringIO.new(TEXT)) }
    assert_match(/read_csv/, e.message)
  end

  def test_from_csv_refuses_encoding
    assert_raise(ArgumentError) { CAFrame.from_csv(TEXT, encoding: "CP932:UTF-8") }
  end

  def test_read_csv_reads_a_path_and_an_io
    Tempfile.create(["obs", ".csv"]) do |f|
      f.write(TEXT)
      f.flush
      assert_equal [1, UNDEF], CAFrame.read_csv(f.path)["k"].to_a
    end
    assert_equal [1, UNDEF], CAFrame.read_csv(StringIO.new(TEXT))["k"].to_a
  end

  def test_write_csv_writes_a_path_and_an_io_and_returns_self
    df = CAFrame.from_csv(TEXT)
    Tempfile.create(["out", ".csv"]) do |f|
      assert_same df, df.write_csv(f.path, index: false)
      assert_equal TEXT, File.read(f.path)
    end
    io = StringIO.new
    assert_same df, df.write_csv(io, index: false)
    assert_equal TEXT, io.string
  end

  def test_to_csv_returns_the_text_write_csv_writes
    df = CAFrame.from_csv(TEXT)
    io = StringIO.new
    df.write_csv(io, sep: ";")
    assert_equal io.string, df.to_csv(sep: ";")
  end

  def test_to_csv_takes_no_path
    assert_raise(ArgumentError) { CAFrame.from_csv(TEXT).to_csv("out.csv") }
  end

  def test_round_trip_through_text
    df = CAFrame.from_csv(TEXT)
    assert_equal df["k"].to_a, CAFrame.from_csv(df.to_csv(index: false))["k"].to_a
  end
end
