require "test/unit"
require "stringio"
require "carray"

# The C reader of a CSV body (CArray.__csv_split__, ext/caframe_csv_split.c)
# against the Ruby tokenizer, which is the reference: every input must read
# to the same frame, or raise the same error, both ways -- whole, and in
# chunks small enough to end inside a quoted field.
class TestCAFrameCSVCReader < Test::Unit::TestCase
  ALPHA = ["a", "b", " ", "\"", "\"\"", "\n", "\r\n", "\r", ",", ";", ":", "x", "\t", "日", ""]

  def setup
    CAFrame  # load the frame
  end

  def read(text, headerless: false, **opts)
    df = headerless ? CAFrame.from_csv(StringIO.new(text), **opts) { |r| r.data } : CAFrame.from_csv(StringIO.new(text), **opts)
    [:ok, df.variable_names, df.variables.map(&:to_a)]
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  # The same input read by the Ruby tokenizer alone.
  def read_in_ruby(text, **opts)
    c_split = CArray.method(:__csv_split__)
    CArray.define_singleton_method(:__csv_split__) { |*| nil }
    read(text, **opts)
  ensure
    CArray.define_singleton_method(:__csv_split__, c_split)
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

  def inputs
    rng = Random.new(20)
    texts = []
    [",", ";", "::", "\t"].each do |sep|
      120.times do                                  # mostly malformed
        ncol = rng.rand(1..3)
        head = Array.new(ncol) { |j| "h#{j}" }.join(sep) + "\n"
        body = Array.new(rng.rand(0..5)) { Array.new(rng.rand(1..10)) { ALPHA.sample(random: rng) }.join }.join("\n")
        texts << [head + body, { sep: sep }]
      end
      120.times do                                  # no header, ragged, blank lines
        lines = Array.new(rng.rand(0..6)) do
          if rng.rand(4).zero?
            ["", " ", "\t"].sample(random: rng)
          else
            Array.new(rng.rand(1..3)) { ["a", "", "\"q\"", "\"x#{sep}y\""].sample(random: rng) }.join(sep)
          end
        end
        texts << [lines.join("\n") + "\n", { sep: sep, headerless: true }]
      end
      60.times do                                   # well formed, from to_csv
        ncol = rng.rand(1..4)
        nrow = rng.rand(0..6)
        cols = Array.new(ncol) do
          vals = Array.new(nrow) { rng.rand < 0.1 ? nil : Array.new(rng.rand(0..6)) { ALPHA.sample(random: rng) }.join }
          c = CA_OBJECT(vals.map { |v| v || "" })
          vals.each_with_index { |v, i| c[i] = UNDEF if v.nil? }
          c
        end
        df = CAFrame.new(Array.new(ncol) { |j| ["c#{j}", cols[j]] }.to_h)
        texts << [df.to_csv(sep: sep), { sep: sep }]
      end
    end
    texts
  end

  def test_reads_as_the_ruby_tokenizer
    inputs.each { |text, opts| assert_equal read_in_ruby(text, **opts), read(text, **opts), text.inspect }
  end

  def test_reads_in_chunks_as_the_ruby_tokenizer
    [1, 7].each do |n|
      with_chunk_bytes(n) do
        inputs.each { |text, opts| assert_equal read_in_ruby(text, **opts), read(text, **opts), "#{n}: #{text.inspect}" }
      end
    end
  end

  def test_the_reader_itself
    ncol, cells, records = CArray.__csv_split__("1,2\r\n\"a,b\",\n3\n  \n\"x\ny\",\"q\"\"r\"\n", ",", "\"", 2)
    assert_equal 2, ncol
    assert_equal ["1", "2", "a,b", UNDEF, "3", UNDEF, "x\ny", "q\"r"], cells
    assert_equal 5, records
    assert_equal [1, [UNDEF, "a", UNDEF, " "], 4], CArray.__csv_split__("\na\n\n \n", ",", "\"", 0)
    assert_nil CArray.__csv_split__("a\"b,1\n", ",", "\"", 2)        # a quote in an unquoted field
    assert_nil CArray.__csv_split__("1,2,3\n", ",", "\"", 2)         # a row too long
    assert_nil CArray.__csv_split__("1,2\n".encode("UTF-16LE"), ",", "\"", 2)
  end

  def test_a_file_in_another_encoding_reads_in_ruby
    text = "a,b\n1,2\n".encode("CP932")
    io = StringIO.new(text)
    io.set_encoding("CP932")
    df = CAFrame.from_csv(io)
    assert_equal ["1"], df["a"].to_a
  end
end
