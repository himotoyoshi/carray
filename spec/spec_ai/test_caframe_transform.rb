# frozen_string_literal: true

require "test/unit"
require "carray"

# transform gives a new frame with columns replaced by what the block
# computes from them, keeping the names, the index and the attributes.
class TestCAFrameTransform < Test::Unit::TestCase
  def frame
    a = CA_FLOAT64([1.04, 2.06, 3.01])
    a[1] = UNDEF
    df = CAFrame.new({ "a" => a, "c" => CA_FLOAT64([0.55, 1.42, 2.99]),
                       "s" => CArray.string(%w[x y z]) },
                     axis_name: "t", index: CA_INT32([10, 11, 12]))
    df.set_attr("title", "obs")
    return df
  end

  def test_every_column
    df  = frame.select("a", "c")
    out = df.transform { |col| col.round(1) }
    assert_equal %w[a c], out.column_names
    assert_equal [1.0, UNDEF, 3.0], out["a"].to_a
    assert_equal [0.6, 1.4, 3.0], out["c"].to_a
    assert_equal [10, 11, 12], out.index.to_a
    assert_equal "t", out.axis_name
    assert_equal({ "title" => "obs" }, out.attrs)
    assert_equal [1.04, UNDEF, 3.01], df["a"].to_a        # the receiver is left as it is
  end

  def test_columns_picked_as_select_picks_them
    out = frame.transform("a".."c") { |col| col * 2 }
    assert_equal [1.1, 2.84, 5.98], out["c"].to_a
    assert_equal %w[x y z], out["s"].to_a
    out = frame.transform(/^s$/) { |col, name| col.upcase + name }
    assert_equal %w[Xs Ys Zs], out["s"].to_a
  end

  def test_an_array_and_a_view
    assert_equal [1, 2, 3], frame.transform("c") { |_| [1, 2, 3] }["c"].to_a
    df  = frame
    out = df.transform("c") { |col| col[nil] }
    out["c"][0] = 9.0
    assert_equal 9.0, df["c"][0]
  end

  def test_refusals
    df = frame
    e = assert_raise(ArgumentError) { df.transform("c") { |col| col.mean } }
    assert_match(/keep_rows: true/, e.message)
    assert_raise(ArgumentError) { df.transform("c") { |col| col[0..1] } }
    assert_raise(ArgumentError) { df.transform("c") }
    assert_raise(KeyError) { df.transform("nope") { |col| col } }
    assert_raise(CArray::DataTypeError) { df.transform { |col| col.round(1) } }   # s is text
    assert_equal [0.55, 1.42, 2.99], df["c"].to_a
  end
end
