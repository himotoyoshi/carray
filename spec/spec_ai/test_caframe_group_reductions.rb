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
    assert_raise(ArgumentError) { grp.all("temp") }       # a float column has no all
  end
end
