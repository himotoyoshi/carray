require "test/unit"
require "carray"

# A grouped reduction's fill_value goes to every column and has to suit each;
# a Hash of column name => value fills those columns only.  A number used to
# be put into a string column.
class TestCAFrameGroupFillHash < Test::Unit::TestCase

  def grouped
    df = CAFrame.new("k" => CA_INT32([1, 1, 2]), "x" => CA_FLOAT64([1, 2, 3]),
                     "s" => CArray.string(%w[a b c]))
    df["x"][2] = UNDEF
    df["s"][2] = UNDEF
    df.group_by("k")
  end

  def test_one_value_has_to_suit_every_column
    assert_raise(TypeError) { grouped.min(fill_value: -9) }
    assert_equal [1.5, -9.0], grouped.mean(fill_value: -9)["x"].to_a
  end

  def test_a_hash_fills_by_column
    r = grouped.min(fill_value: { "x" => -9, "s" => "?" })
    assert_equal [1.0, -9.0], r["x"].to_a
    assert_equal ["a", "?"], r["s"].to_a
    r = grouped.min(fill_value: { "x" => -9 })
    assert_equal ["a", UNDEF], r["s"].to_a
    assert_equal [1.0, -1.0], grouped.min("x", fill_value: { "x" => -1 }).to_a
  end

  def test_an_unknown_column_is_refused
    assert_raise(ArgumentError) { grouped.min(fill_value: { "zz" => 1 }) }
  end

end
