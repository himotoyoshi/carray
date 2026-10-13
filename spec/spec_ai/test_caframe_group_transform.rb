require "test/unit"
require "carray"

# A grouped frame's within-group transforms (lag, order and the running
# scans) keep the frame's rows: each row gets its group's value, as the
# column's group iterator gives it.

class TestCAFrameGroupTransform < Test::Unit::TestCase

  OPS = { lag: [[], { n: 1 }], order: [[], {}], cumsum: [[], {}], cumprod: [[], {}],
          cummax: [[], {}], cummin: [[], {}], cumcount: [[], {}] }.freeze

  def frame
    station = CA_OBJECT(%w[tokyo osaka tokyo osaka tokyo osaka])
    station[5] = UNDEF
    CAFrame.new("station" => station,
                "temp"    => CA_FLOAT64([10, 20, 11, 22, 9, 30]),
                "time"    => CArray.time_series("2024-01-01", count: 6, unit: :D),
                "wind"    => CArray.float64(6, 2) { |i, j| i * 10 + j })
  end

  # The column's own group iterator gives the reference answer.
  def iterator_answer (df, name, op, kw)
    col = df[name]
    it  = col.group_by_category(df["station"].categorize)
    it_kw = op == :lag ? {} : kw
    args  = op == :lag ? [kw[:n]] : []
    it_kw = it_kw.merge(axis: 0) if col.ndim > 1
    it.public_send(op, *args, **it_kw)
  end

  def test_named_column_matches_the_iterator
    df  = frame
    grp = df.group_by("station")
    OPS.each do |op, (_, kw)|
      %w[temp wind].each do |name|
        assert_equal iterator_answer(df, name, op, kw).to_a, grp.public_send(op, name, **kw).to_a,
                     "#{op} #{name}"
      end
    end
  end

  def test_lag_and_order
    grp = frame.group_by("station")
    assert_equal [UNDEF, UNDEF, 10.0, 20.0, 11.0, UNDEF], grp.lag("temp").to_a
    assert_equal [11.0, 22.0, 9.0, UNDEF, UNDEF, UNDEF], grp.lag("temp", n: -1).to_a
    assert_equal [1, 0, 2, 1, 0, UNDEF], grp.order("temp").to_a
    assert_equal [1, 1, 0, 0, 2, UNDEF], grp.order("temp", descending: true).to_a
  end

  def test_several_names
    grp = frame.group_by("station")
    temp, wind = grp.lag("temp", "wind")
    assert_equal grp.lag("temp").to_a, temp.to_a
    assert_equal [6, 2], wind.shape
    assert_equal [0.0, 1.0], wind[2, nil].to_a
  end

  # Without names: every column that has the operation, on the frame's
  # rows and index, the keys left out.
  def test_frame_form
    df  = frame.set_index("temp")
    grp = df.group_by("station")
    lagged = grp.lag
    assert_equal %w[time wind], lagged.column_names
    assert_equal df.index.to_a, lagged.index.to_a
    assert_equal df.nrow, lagged.nrow
    # a sum of instants is refused by a time column, so it is left out
    assert_equal %w[wind], grp.cumsum.column_names
  end

  def test_a_named_column_without_the_operation_raises
    grp = frame.group_by("station")
    assert_raise(CArray::DataTypeError) { grp.cumsum("time") }
    assert_raise(KeyError) { grp.lag("nope") }
  end

  # A wrong keyword is refused, rather than leaving every column out.
  def test_keywords_are_checked
    grp = frame.group_by("station")
    assert_raise(ArgumentError) { grp.order(method: :average) }
    assert_raise(ArgumentError) { grp.order("temp", kind: :merge) }
    assert_raise(TypeError) { grp.lag(n: 1.5) }
    assert_raise(TypeError) { grp.lag("temp", 1) }   # n is a keyword, 1 is not a column name
  end

  def test_resample_groups
    t  = CArray.time_range("2024-01-01T00:00", "2024-01-01T05:00", unit: :h)
    df = CAFrame.new("time" => t, "v" => CA_FLOAT64([1, 2, 3, 4, 5, 6])).set_index("time")
    grp = df.resample("time", "3 hours")
    assert_equal [UNDEF, 1.0, 2.0, UNDEF, 4.0, 5.0], grp.lag("v").to_a
    assert_equal [1.0, 3.0, 6.0, 4.0, 9.0, 15.0], grp.cumsum("v").to_a
  end
end
