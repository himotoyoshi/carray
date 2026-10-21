# frozen_string_literal: true

require "test/unit"
require "carray"

# nlargest / nsmallest give the n rows with the largest / smallest keys.
class TestCAFrameNLargest < Test::Unit::TestCase
  def frame
    v = CA_FLOAT64([3, Float::NAN, 5, 1, 4, 5])
    v[3] = UNDEF
    CAFrame.new({ "v" => v, "k" => CA_INT32([0, 1, 2, 3, 4, 9]),
                  "s" => CArray.string(%w[a b c d e f]) },
                axis_name: "row", index: CA_INT32([10, 11, 12, 13, 14, 15]))
  end

  def test_largest_first
    out = frame.nlargest(3, "v")
    assert_equal [5.0, 5.0, 4.0], out["v"].to_a
    assert_equal [12, 15, 14], out.index.to_a        # ties keep their order
  end

  def test_smallest_first
    assert_equal [3.0, 4.0], frame.nsmallest(2, "v")["v"].to_a
  end

  def test_a_second_key_breaks_ties
    assert_equal [15, 12], frame.nlargest(2, "v", "k").index.to_a
  end

  def test_nan_and_masked_come_last
    assert_equal [11, 13], frame.nlargest(6, "v").index.to_a[4..]
    assert_equal [11, 13], frame.nsmallest(10, "v").index.to_a[4..]
  end

  def test_text_and_index_keys
    assert_equal %w[f e], frame.nlargest(2, "s")["s"].to_a
    assert_equal [15], frame.nlargest(1, "row").index.to_a
  end

  def test_a_view_of_the_frame
    df  = frame
    out = df.nlargest(1, "k")
    out["v"][0] = -1.0
    assert_equal(-1.0, df["v"][5])
  end

  def test_refusals
    assert_raise(ArgumentError) { frame.nlargest(-1, "v") }
    assert_raise(ArgumentError) { frame.nlargest(2) }
    assert_raise(TypeError) { frame.nlargest(1.5, "v") }
    assert_raise(TypeError) { frame.nlargest(2, :v) }
    assert_raise(KeyError) { frame.nlargest(2, "nope") }
    assert_equal 0, frame.nlargest(0, "v").nrow
    e = assert_raise(KeyError) { frame.nlargest(1, "nope") }
    assert_match(/\Anlargest:/, e.message)
    df = CAFrame.new("c" => CA_OBJECT(%w[a b]).categorize)
    e = assert_raise(ArgumentError) { df.nsmallest(1, "c") }
    assert_match(/\Ansmallest: the column "c" cannot be sorted/, e.message)
  end
end
