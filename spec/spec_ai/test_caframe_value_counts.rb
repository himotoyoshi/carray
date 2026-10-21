# frozen_string_literal: true

require "test/unit"
require "carray"

# CAFrame#value_counts: how many rows hold each value, or each combination of
# values, as a frame.
class TestCAFrameValueCounts < Test::Unit::TestCase
  def frame
    s = CA_OBJECT(%w[b a b c b a c])
    s[6] = UNDEF
    CAFrame.new("s" => s, "t" => CA_INT32([1, 1, 1, 2, 2, 1, 1]))
  end

  def test_one_column
    out = frame.value_counts("s")
    assert_equal "s", out.axis_name
    assert_equal %w[b a c], out.index.to_a
    assert_equal [3, 2, 1], out["count"].to_a           # the masked row not counted
  end

  def test_sort
    df = frame
    out = df.value_counts("s", sort: :value)
    assert_equal %w[a b c], out.index.to_a
    assert_equal [2, 3, 1], out["count"].to_a
    assert_equal %w[b a c], df.value_counts("s", sort: false).index.to_a
  end

  def test_several_columns_and_every_column
    df = frame
    assert_equal [["b", 1, 2], ["a", 1, 2], ["c", 2, 1], ["b", 2, 1]], df.value_counts.to_a
    assert_equal [["a", 1, 2], ["b", 1, 2], ["b", 2, 1], ["c", 2, 1]],
                 df.value_counts("s", "t", sort: :value).to_a
    assert_equal %w[s t n], df.value_counts(name: "n").column_names
  end

  def test_refusals
    df = frame
    assert_raise(ArgumentError) { df.value_counts("s", sort: :x) }
    e = assert_raise(ArgumentError) { df.value_counts("s", name: "s") }
    assert_match(/value_counts\(\.\.\., name:/, e.message)
    e = assert_raise(KeyError) { df.value_counts("nope") }
    assert_match(/\Avalue_counts:/, e.message)
  end
end
