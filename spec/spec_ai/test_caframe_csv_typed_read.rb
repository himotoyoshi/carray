require "test/unit"
require "stringio"
require "carray"

# from_csv with types: reads the body into CAConstString columns (no String
# per cell), casts from those, and hands the columns left as text back as
# CAString. It must give the frame the other two ways give: the Ruby
# tokenizer, and reading without types: and casting afterwards -- the same
# names, column classes, data types, values and masks, or the same error.
class TestCAFrameCSVTypedRead < Test::Unit::TestCase

  CELLS = ["1", "-2", "007", "3.5", "-0.0", "1e3", "nan", "inf", "", "\"\"", "\"4\"",
           "\"x,y\"", "\"a\"\"b\"", "x", " 5 ", "2024-01-02", "2024-01-02 03:04:05",
           "99999999999999999999", "日本"]

  def setup
    CAFrame  # load the frame
  end

  def describe(df)
    [:ok, df.variable_names, df.variables.map(&:class), df.variables.map(&:data_type),
     df.variables.map { |c| c.to_a.map { |v| v.is_a?(Float) && v.nan? ? :nan : v } },
     df.variables.map { |c| c.is_masked.to_a }]
  end

  def read(text, **opts)
    describe(CAFrame.from_csv(StringIO.new(text), **opts))
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  # The same input read by the Ruby tokenizer alone.
  def read_in_ruby(text, **opts)
    readers = %i[__csv_read_body_as_string_cells__ __csv_read_body_as_const_string_columns__]
    saved = readers.map { |m| CArray.method(m) }
    readers.each { |m| CArray.define_singleton_method(m) { |*| nil } }
    read(text, **opts)
  ensure
    readers.zip(saved) { |m, f| CArray.define_singleton_method(m, f) }
  end

  # The same input read without types:, cast afterwards.
  def read_then_cast(text, types)
    df = CAFrame.from_csv(StringIO.new(text))
    df.cast(types == :infer ? df.infer_types : types)
    describe(df)
  rescue StandardError => e
    [:error, e.class, e.message]
  end

  def inputs
    rng = Random.new(1009)
    texts = []
    200.times do
      ncol = rng.rand(1..4)
      head = Array.new(ncol) { |j| "c#{j}" }.join(",")
      col_cells = Array.new(ncol) { CELLS.sample(rng.rand(1..3), random: rng) }
      rows = Array.new(rng.rand(0..6)) do
        Array.new(rng.rand(1..ncol)) { |j| col_cells[j].sample(random: rng) }.join(",")
      end
      rows.insert(rng.rand(0..rows.size), "") if rng.rand(5).zero?     # a blank line
      eol = rng.rand(4).zero? ? "\r\n" : "\n"
      texts << ([head] + rows).join(eol) + eol
    end
    texts << "a,b\n1,\"2\n" << "a,b\n1,2,3\n" << "a,b\n1,x\"y\n" << "a\n" << ""
    texts
  end

  def test_reads_as_the_ruby_tokenizer
    inputs.each do |text|
      assert_equal read_in_ruby(text, types: :infer), read(text, types: :infer), text.inspect
    end
  end

  def test_reads_as_reading_untyped_and_casting
    inputs.each do |text|
      typed = read(text, types: :infer)
      next if typed[0] == :error
      assert_equal read_then_cast(text, :infer), typed, text.inspect
    end
  end

  def test_a_map_of_types_reads_as_casting
    text = "a,b,c\n1,2.5,x\n,\"3\",\"y,\"\"z\"\"\"\n4,bad,\n"
    types = { "a" => :int32, "b" => :float64 }
    assert_equal read_then_cast(text, types), read(text, types: types)
    df = CAFrame.from_csv(StringIO.new(text), types: types)
    assert_equal [:int32, :float64, :object], df.variables.map(&:data_type)
    assert_kind_of CAString, df["c"]
  end

  def test_a_text_column_writes_through_to_a_view_of_the_frame
    df = CAFrame.from_csv(StringIO.new("a,b\n1, x \n2,y\n3,z\n"), types: { "a" => :int64 })
    sub = df.filter { |r| r["a"] > 1 }
    df["b"][1] = "W"
    df["b"].strip!
    assert_equal ["x", "W", "z"], df["b"].to_a
    assert_equal ["W", "z"], sub["b"].to_a
  end

end
