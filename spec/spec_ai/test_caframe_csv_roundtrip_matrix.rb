$:.unshift File.expand_path("../../ext", __dir__)
$:.unshift File.expand_path("../../lib", __dir__)
require "test/unit"
require "carray"

# What a frame written with to_csv gives back through read_csv, for every
# kind of column a frame holds. Each kind is written with and without a
# masked cell, beside another column and alone (a frame of one column writes
# a masked cell as an empty line), and read by the C reader and by the Ruby
# tokenizer. A kind gives back two things: what inference makes of its text,
# and what it comes back as when read with the types: entry that names it.
#
# Every data type and every Face is either in KINDS or in UNWRITABLE, so a
# new type fails here until its round trip is written down.
class TestCAFrameCSVRoundtripMatrix < Test::Unit::TestCase

  def self.short_float32 (v)
    return v if v.nan? || v.infinite? || v.zero?
    (1..9).each do |p|
      s = "%.#{p}g" % v
      return Float(s) if [Float(s)].pack("f") == [v].pack("f")
    end
    v
  end

  def self.bits (v, pack = "G")
    case v
    when Complex then [v.real, v.imag].pack(pack * 2)
    when Float   then [v].pack(pack)
    else v
    end
  end

  SAME   = ->(o, b) { bits(o) == bits(b) }
  AS_TEXT = ->(o, b) { b == o.to_s }

  # name => { make: cells (3 of them), source: the data type or Face it
  # stands for, infer: [type label, cell rule] when no types: is given,
  # typed: [types: entry, type label] or nil when no entry gives the kind
  # back }.
  KINDS = {
    "int8"     => { source: "int8",   make: -> { CA_INT8([-128, 0, 127]) },              infer: ["int64", SAME], typed: [:int8, "int8"] },
    "uint8"    => { source: "uint8",  make: -> { CA_UINT8([0, 1, 255]) },                infer: ["int64", SAME], typed: [:uint8, "uint8"] },
    "int16"    => { source: "int16",  make: -> { CA_INT16([-32768, 5, 32767]) },         infer: ["int64", SAME], typed: [:int16, "int16"] },
    "uint16"   => { source: "uint16", make: -> { CA_UINT16([0, 7, 65535]) },             infer: ["int64", SAME], typed: [:uint16, "uint16"] },
    "int32"    => { source: "int32",  make: -> { CA_INT32([-2**31, 3, 2**31 - 1]) },     infer: ["int64", SAME], typed: [:int32, "int32"] },
    "uint32"   => { source: "uint32", make: -> { CA_UINT32([0, 3, 2**32 - 1]) },         infer: ["int64", SAME], typed: [:uint32, "uint32"] },
    "int64"    => { source: "int64",  make: -> { CA_INT64([-2**63, 3, 2**63 - 1]) },     infer: ["int64", SAME], typed: [:int64, "int64"] },
    # An integer too long for int64 is an identifier: the column stays text.
    "uint64"   => { source: "uint64", make: -> { CA_UINT64([0, 3, 2**64 - 1]) },         infer: ["CAString", AS_TEXT], typed: [:uint64, "uint64"] },
    "uint64_small" => { source: "uint64", make: -> { CA_UINT64([0, 3, 2**63 - 1]) },     infer: ["int64", SAME], typed: [:uint64, "uint64"] },
    # A float32 is written as the shortest decimal that reads back as it.
    "float32"  => { source: "float32", make: -> { CA_FLOAT32([0.1, -0.0, 3.4e38]) },
                    infer: ["float64", ->(o, b) { bits(short_float32(o)) == bits(b) }], typed: [:float32, "float32"] },
    "float64"  => { source: "float64", make: -> { CA_FLOAT64([0.1, -0.0, Float::MAX]) }, infer: ["float64", SAME], typed: [:float64, "float64"] },
    "float64_tiny" => { source: "float64", make: -> { CA_FLOAT64([5e-324, -2.2250738585072014e-308, 1e300]) }, infer: ["float64", SAME], typed: [:float64, "float64"] },
    "float64_special" => { source: "float64", make: -> { CA_FLOAT64([Float::NAN, Float::INFINITY, -Float::INFINITY]) }, infer: ["float64", SAME], typed: [:float64, "float64"] },
    "float64_whole" => { source: "float64", make: -> { CA_FLOAT64([2.0**60, 1.0, -3.0]) }, infer: ["float64", SAME], typed: [:float64, "float64"] },
    # A complex is not inferred: its text comes back.
    "cmplx64"  => { source: "cmplx64", make: -> { CA_CMPLX64([Complex(0.1, -0.2), 1, Complex(0, 3)]) },
                    infer: ["CAString", ->(o, b) { bits(Complex(b), "f") == bits(o, "f") }], typed: [:cmplx64, "cmplx64"] },
    "cmplx128" => { source: "cmplx128", make: -> { CA_CMPLX128([Complex(0.1, -0.2), 1, Complex(-0.0, 3)]) },
                    infer: ["CAString", ->(o, b) { bits(Complex(b)) == bits(o) }], typed: [:cmplx128, "cmplx128"] },
    # A boolean is written 1 / 0, which inference reads as integers.
    "boolean"  => { source: "boolean", make: -> { CA_BOOLEAN([true, false, true]) },
                    infer: ["int64", ->(o, b) { b == (o ? 1 : 0) }], typed: [:boolean, "boolean"] },
    "object_int" => { source: "object", make: -> { CA_OBJECT([1, 2, 3]) },               infer: ["int64", SAME], typed: [:int64, "int64"] },
    "object_text" => { source: "object", make: -> { CA_OBJECT(%w[a b c]) },              infer: ["CAString", SAME], typed: [:string, "CAString"] },
    "fixlen"   => { source: "fixlen", make: -> { f = CArray.new(CA_FIXLEN, [3], bytes: 2); f[0] = "ab"; f[1] = "cd"; f[2] = "ef"; f },
                    infer: ["CAString", SAME], typed: [:string, "CAString"] },
    "string"   => { source: "CAString", make: -> { CArray.string(["a,b", "q\"q", "line\nx"]) }, infer: ["CAString", SAME], typed: [:string, "CAString"] },
    "string_blank" => { source: "CAString", make: -> { CArray.string(["", " \t ", " sp 日本 "]) }, infer: ["CAString", SAME], typed: [:string, "CAString"] },
    # A number with a leading zero is a code.
    "string_code" => { source: "CAString", make: -> { CArray.string(%w[007 010 1]) },    infer: ["CAString", SAME], typed: [:string, "CAString"] },
    # No types: entry makes these again: they come back as CAString.
    "fixlen_string" => { source: "CAFixlenString", make: -> { CArray.fixlen_string(%w[ab cd ef]) }, infer: ["CAString", SAME], typed: nil },
    "const_string"  => { source: "CAConstString", make: -> { CArray.string(%w[a bb c]).to_const_string }, infer: ["CAString", SAME], typed: nil },
    # A categorical comes back as text; types: makes one again.
    "categorical" => { source: "CACategorical", make: -> { CA_OBJECT(%w[b a b]).categorize }, infer: ["CAString", SAME], typed: [:categorical, "CACategorical"] },
    "time_D"   => { source: "CATime", make: -> { CArray.time(%w[2024-01-01 1969-12-31 2262-01-01], unit: :D) }, infer: ["CATime[D]", SAME], typed: [:time, "CATime[D]"] },
    "time_s"   => { source: "CATime", make: -> { CArray.time(%w[2024-01-01T01:02:03 1969-12-31T23:59:59 2024-02-29T00:00:00], unit: :s) }, infer: ["CATime[s]", SAME], typed: [:time, "CATime[s]"] },
    "time_ns"  => { source: "CATime", make: -> { CArray.time(%w[2024-01-01T01:02:03.000000001 1700-01-01 2262-04-11], unit: :ns) }, infer: ["CATime[ns]", SAME], typed: [:time, "CATime[ns]"] },
    # A time comes back in the finest unit its text shows.
    "time_h"   => { source: "CATime", make: -> { CArray.time(%w[2024-01-01T01 2024-01-01T02 2024-01-01T03], unit: :h) }, infer: ["CATime[s]", SAME], typed: [:time, "CATime[s]"] },
    "time_10m" => { source: "CATime", make: -> { CArray.time(%w[2024-01-01T00:10 2024-01-01T00:20 2024-01-01T00:30], unit: "10 minutes") }, infer: ["CATime[s]", SAME], typed: [:time, "CATime[s]"] },
    # A month or a year is read as a time only when types: says so.
    "time_M"   => { source: "CATime", make: -> { CArray.time(%w[2024-01 1969-12 2024-03], unit: :M) }, infer: ["CAString", AS_TEXT], typed: [:time, "CATime[M]"] },
    "time_Y"   => { source: "CATime", make: -> { CArray.time(%w[2024 1969 1000], unit: :Y) }, infer: ["int64", ->(o, b) { b == Integer(o.to_s) }], typed: [:time, "CATime[Y]"] },
    # A duration is never inferred.
    "timedelta_s" => { source: "CATimedelta", make: -> { t = CArray.time(%w[2024-01-01T00:00:00 2024-01-01T01:02:03 2023-12-31T23:00:00], unit: :s); t - t[0] },
                       infer: ["CAString", AS_TEXT], typed: [:timedelta, "CATimedelta[s]"] },
  }

  # Kinds a CSV cell cannot hold: writing them is refused.
  UNWRITABLE = {
    "CARecord" => -> { CARecord.new(CArray.struct { int32 :a; float64 :b }, 3) },
  }

  def label (col) = CArray::Inspector.type_label(col)

  # The cells with the middle one masked, for a kind whose column is read-only.
  def masked (col)
    case col
    when CACategorical then o = CA_OBJECT(col.to_a); o[1] = UNDEF; o.categorize
    when CAConstString then s = col.to_string.copy; s[1] = UNDEF; s.to_const_string
    else c = col.copy; c[1] = UNDEF; c
    end
  end

  def in_ruby
    c_split = CArray.method(:__csv_read_body_as_string_cells__)
    CArray.define_singleton_method(:__csv_read_body_as_string_cells__) { |*| nil }
    yield
  ensure
    CArray.define_singleton_method(:__csv_read_body_as_string_cells__, c_split)
  end

  def readers
    [[:c, ->(&b) { b.call }], [:ruby, ->(&b) { in_ruby(&b) }]]
  end

  def frames (col)
    [["beside", CAFrame.new("c" => col, "z" => CA_INT32(Array.new(col.elements) { |i| i }))],
     ["alone",  CAFrame.new("c" => col)]]
  end

  def assert_cells (orig, back, rule, where)
    assert_equal orig.elements, back.elements, "#{where}: rows"
    orig.to_a.zip(back.to_a).each_with_index do |(o, b), i|
      if o.equal?(UNDEF)
        assert b.equal?(UNDEF), "#{where}: row #{i} masked, read back #{b.inspect}"
      else
        assert !b.equal?(UNDEF) && rule.call(o, b), "#{where}: row #{i} #{o.inspect} read back #{b.inspect}"
      end
    end
  end

  KINDS.each do |name, kind|
    define_method("test_#{name}") do
      base = kind[:make].call
      [["plain", base], ["masked", masked(base)]].each do |state, col|
        frames(col).each do |shape, df|
          text = df.to_csv
          readers.each do |reader, run|
            where = "#{name} #{state} #{shape} #{reader}"
            back = run.call { CAFrame.from_csv(text) }
            assert_equal df.column_names, back.column_names, where
            assert_equal kind[:infer][0], label(back["c"]), "#{where}: inferred type"
            assert_cells(col, back["c"], kind[:infer][1], where)
            next unless kind[:typed]
            typed = run.call { CAFrame.from_csv(text, types: { "c" => kind[:typed][0] }) }
            assert_equal kind[:typed][1], label(typed["c"]), "#{where}: typed type"
            assert_cells(col, typed["c"], SAME, "#{where} typed")
          end
        end
      end
    end
  end

  UNWRITABLE.each do |name, make|
    define_method("test_#{name}_is_refused") do
      assert_raise(ArgumentError) { CAFrame.new("c" => make.call).to_csv }
    end
  end

  # The frame around the columns: the index, a frame with no rows, attributes.
  def test_the_index_comes_back_as_the_first_column
    df = CAFrame.new({ "v" => CA_INT32([1, 2]) }, index: CArray.string(%w[a b]), axis_name: "id")
    readers.each do |reader, run|
      back = run.call { CAFrame.from_csv(df.to_csv) }
      assert_equal %w[id v], back.column_names, reader.to_s
      assert_equal df, back.set_index("id").cast("v" => :int32), reader.to_s
    end
  end

  def test_names_that_need_quoting_come_back
    names = ["a,b", "q\"q", "line\nx", " \t ", "日本", "-999"]
    names.each do |name|
      [[name], [name, "z"]].each do |cols|
        df = CAFrame.new(cols.to_h { |c| [c, CA_INT32([1, 2])] })
        readers.each do |reader, run|
          back = run.call { CAFrame.from_csv(df.to_csv) }
          assert_equal cols, back.column_names, "#{name.inspect} #{cols.size} #{reader}"
          assert_equal 2, back.nrow, "#{name.inspect} #{cols.size} #{reader}"
        end
      end
    end
  end

  def test_a_frame_with_no_rows_keeps_its_names
    df = CAFrame.new("a" => CA_INT32([]), "b" => CArray.string([]))
    readers.each do |reader, run|
      back = run.call { CAFrame.from_csv(df.to_csv) }
      assert_equal %w[a b], back.column_names, reader.to_s
      assert_equal 0, back.nrow, reader.to_s
    end
  end

  def test_attributes_come_back_as_strings
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([3, 4]))
    df["a"].set_attr(:units, "K")
    df["b"].set_attr(:units, 10)
    readers.each do |reader, run|
      back = run.call { CAFrame.from_csv(df.to_csv(attrs: [:units]), attrs: [:units]) }
      assert_equal ["K", "10"], back.columns.map { |c| c.attr(:units) }, reader.to_s
      assert_equal [[1, 3], [2, 4]], back.to_a, reader.to_s
    end
  end

  # Frames drawn at random from KINDS, each column read with its types:
  # entry, so every cell, masked or not, has to come back as it was.
  def test_random_frames_come_back_cell_for_cell
    rng = Random.new(20261103)
    typed = KINDS.select { |_, k| k[:typed] }
    200.times do |n|
      picks = typed.keys.sample(rng.rand(1..4), random: rng)
      nrow = rng.rand(0..6)
      cols = picks.each_with_index.to_h do |name, j|
        base = typed[name][:make].call
        col = base[CA_INT64(Array.new(nrow) { rng.rand(3) })]
        col = col.copy
        col = masked_at(col, Array.new(nrow) { rng.rand(4).zero? })
        ["c#{j}", col]
      end
      df = CAFrame.new(cols)
      types = picks.each_with_index.to_h { |name, j| ["c#{j}", typed[name][:typed][0]] }
      readers.each do |reader, run|
        back = run.call { CAFrame.from_csv(df.to_csv, types: types) }
        where = "frame #{n} #{picks.inspect} #{reader}"
        assert_equal df.column_names, back.column_names, where
        assert_equal nrow, back.nrow, where
        cols.each { |c, col| assert_cells(col, back[c], SAME, "#{where} #{c}") }
      end
    end
  end

  def masked_at (col, flags)
    return col unless flags.any?
    case col
    when CACategorical
      o = CA_OBJECT(col.to_a); flags.each_with_index { |f, i| o[i] = UNDEF if f }; o.categorize
    else
      flags.each_with_index { |f, i| col[i] = UNDEF if f }
      col
    end
  end

  # Every data type and every Face is written down above.
  def test_every_data_type_has_a_kind
    names = (0..CA_OBJECT_TYPE_CODE_LIMIT).filter_map { |i| CArray.data_type_name(i) rescue nil }
    sources = KINDS.values.map { |k| k[:source] }
    assert_equal [], names - sources, "a data type has no CSV round trip in KINDS"
  end

  def test_every_face_has_a_kind
    faces = ObjectSpace.each_object(Class).select { |k| k.name && k < CAFace }.map(&:name)
    sources = KINDS.values.map { |k| k[:source] } + UNWRITABLE.keys
    assert_equal [], faces.sort - sources, "a Face has no CSV round trip in KINDS or UNWRITABLE"
  end

  CA_OBJECT_TYPE_CODE_LIMIT = 63
end
