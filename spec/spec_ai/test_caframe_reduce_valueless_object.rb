# frozen_string_literal: true

require "test/unit"
require "carray"

# A reduction over every column leaves out an object column with no present
# value, whose kind cannot be told, as select leaves it out of every kind.
class TestCAFrameReduceValuelessObject < Test::Unit::TestCase
  def frame
    CAFrame.new("n" => CA_FLOAT64([1, 2]), "s" => CA_OBJECT(%w[a b]), "o" => CA_OBJECT([1, 2]))
  end

  def test_a_frame_with_no_rows
    z = frame[0...0]
    assert_equal ["n"], z.sum.column_names
    assert_equal ["n"], z.mean.column_names
    assert_equal ["n", "s", "o"], z.count.column_names
  end

  def test_an_all_masked_object_column
    s = CA_OBJECT(%w[a b])
    s[nil] = UNDEF
    assert_equal ["n"], CAFrame.new("n" => CA_FLOAT64([1, 2]), "s" => s).sum.column_names
  end

  def test_a_named_column_is_still_reduced
    assert_equal ["o"], frame[0...0].sum("o").column_names
  end
end
