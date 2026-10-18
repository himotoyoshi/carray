require "test/unit"
require "carray"

# Every reduction a grouped frame offers in the short form answers, for each
# column whose type has it, what the core reduction gives on that group's
# rows; a column whose type lacks it is left out, and the key is never a
# result column.

class TestCAFrameGroupReductions < Test::Unit::TestCase

  WITH_COUNT = %i[sum mean min max prod accumulate median
                  variance stddev variancep stddevp].freeze
  PLAIN      = %i[first last nunique count all any].freeze

  def frame
    station = CA_OBJECT(%w[a b a b a b])
    station[5] = UNDEF
    temp = CA_FLOAT64([10, 20, 12, 22, 10, 30])
    temp[3] = UNDEF
    CAFrame.new("station" => station, "temp" => temp,
                "n"       => CA_INT32([3, 1, 4, 1, 5, 9]),
                "rain"    => CA_BOOLEAN([true, false, false, false, true, true]),
                "time"    => CArray.time_series("2024-01-01", count: 6, unit: :D),
                "wind"    => CArray.float64(6, 2) { |i, j| i * 10 + j })
  end

  # The rows of each group, as the core would see them, reduced along the
  # rows as the group reduces them (a 1-D column as one column of rows).
  ROWS = [[0, 2, 4], [1, 3]].freeze

  def core_answer (col, red, kw)
    ROWS.map do |rows|
      piece = col[CA_INT64(rows), *[nil] * (col.ndim - 1)].copy
      if col.ndim > 1
        piece.public_send(red, axis: 0, **kw).to_a
      else
        piece.reshape(rows.size, 1).public_send(red, axis: 0, **kw).to_a[0]
      end
    end
  end

  def plain (v)
    case v
    when Array then v.map { |x| plain(x) }
    when CATime::Element, CATimedelta::Element then v.to_s
    when Float then v.round(9)
    else v
    end
  end

  def has? (col, red)
    probe = col[0..0, *[nil] * (col.ndim - 1)]
    col.ndim > 1 ? probe.public_send(red, axis: 0) : probe.public_send(red)
    true
  rescue CArray::DataTypeError, TypeError, ArgumentError
    false
  end

  (WITH_COUNT + PLAIN).each do |red|
    define_method("test_#{red}_matches_the_core_per_group") do
      df  = frame
      res = df.group_by("station").public_send(red)
      expected = df.column_names.reject { |n| n == "station" }.select { |n| has?(df[n], red) }
      assert_equal expected, res.column_names
      expected.each do |name|
        got = res[name].to_a
        assert_equal plain(core_answer(df[name], red, {})), plain(got), "#{red} #{name}"
      end
    end
  end

  def test_named_columns_and_keep_rows
    grp = frame.group_by("station")
    assert_equal [10.0, 20.0], grp.median("temp").to_a
    temp, n = grp.first("temp", "n")
    assert_equal [10.0, 20.0], temp.to_a
    assert_equal [3, 1], n.to_a
    assert_equal [3, 1, 3, 1, 3, UNDEF], grp.count("temp", keep_rows: true).to_a
  end

  def test_keywords
    grp = frame.group_by("station")
    assert_equal [1.3333333333, UNDEF], grp.variance("temp", min_count: 3).to_a.map { |v| v.is_a?(Float) ? v.round(10) : v }
    assert_equal [10.0, -1.0], grp.median("temp", min_count: 2, fill_value: -1.0).to_a
    assert_raise(ArgumentError) { grp.first("temp", min_count: 1) }
    assert_raise(CArray::DataTypeError) { grp.all("temp") }   # a float column has no all
  end

  # count with no value counts the present cells of any type, a Face's
  # included, though CACategorical#count itself takes a label.
  def test_count_counts_a_categorical_column
    c = CA_OBJECT(["x", nil, "x", "z"])
    c[1] = UNDEF
    df = CAFrame.new("k" => CA_INT32([1, 1, 2, 2]), "c" => c.categorize,
                     "f" => CA_FLOAT64([1, 2, 3, 4]))
    grp = df.group_by("k")
    assert_equal [1, 2], grp.count("c").to_a
    assert_equal %w[c f], grp.count.column_names
    assert_equal [1, 1, 1, 2],
                 df.windows(on: "f", before: 1, exclude: nil).count("c").to_a
  end

  # With no group at all, keep_rows: answers in the type the reduction has.
  def test_keep_rows_with_no_group_keeps_the_type
    k = CArray.float64(3)
    k[] = UNDEF
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D)
    grp = CAFrame.new("k" => k, "t" => t).group_by("k")
    got = grp.mean("t", keep_rows: true)
    assert_kind_of CATime, got
    assert_equal [UNDEF] * 3, got.to_a
  end

  # A group's key in the result is the key at the group's first row, which
  # shows when equal keys differ in form: -0.0 and 0.0 are one group.
  def test_the_key_of_a_group_is_its_first_rows
    df = CAFrame.new("k" => CA_FLOAT64([-0.0, 1.0, 0.0, 1.0]), "x" => CA_FLOAT64([1, 2, 3, 4]))
    assert_equal [-Float::INFINITY, 1.0], df.group_by("k").sum.index.to_a.map { |v| 1.0 / v }
    df = CAFrame.new("k" => CA_FLOAT64([0.0, 1.0, -0.0, 1.0]), "x" => CA_FLOAT64([1, 2, 3, 4]))
    assert_equal [Float::INFINITY, 1.0], df.group_by("k").sum.index.to_a.map { |v| 1.0 / v }
  end

  def test_the_key_columns_of_a_group_are_its_first_rows
    k = CA_FLOAT64([1.0, -0.0, 0.0, 0.0])
    k[0] = UNDEF                                   # a row in no group comes first
    df = CAFrame.new("a" => k, "b" => CA_INT64([1, 1, 1, 1]), "x" => CA_FLOAT64([1, 2, 3, 4]))
    got = df.group_by("a", "b").sum
    assert_equal [-Float::INFINITY], got["a"].to_a.map { |v| 1.0 / v }
    assert_equal [9.0], got["x"].to_a
  end

  # A text column has a min but no median (two Strings do not interpolate)
  # and no sum, so a frame-wide median and sum leave it out, as the doc says.
  def test_frame_wide_median_leaves_out_a_text_column
    df = CAFrame.new("k" => [1, 2, 1], "s" => %w[a b a], "v" => [1.0, 2.0, 3.0])
    assert_equal ["v"], df.group_by("k").median.column_names
    assert_equal ["v"], df.group_by("k").sum.column_names
    assert_equal ["s", "v"], df.group_by("k").min.column_names
  end

  # A frame with no rows answers each reduction with the columns and the
  # kinds a frame with rows does.
  def test_a_frame_with_no_rows_answers_as_one_with_rows
    df = CAFrame.new("k" => [1, 2, 1], "s" => %w[a b a],
                     "t" => CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D),
                     "v" => [1.0, 2.0, 3.0])
    empty = df.filter { |f| f["v"] > 99 }
    kinds = ->(f) { f.column_names.map { |c| [c, CArray::Inspector.type_label(f[c])] } }
    %i[sum mean median min max first stddev].each do |verb|
      assert_equal kinds.(df.group_by("k").send(verb)),
                   kinds.(empty.group_by("k").send(verb)), verb.to_s
    end
  end
end
