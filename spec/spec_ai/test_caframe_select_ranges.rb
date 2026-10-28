# frozen_string_literal: true

require "test/unit"
require "carray"

# select and drop take a Range of names and a Regexp, as stack_columns does.
class TestCAFrameSelectRanges < Test::Unit::TestCase
  def frame
    CAFrame.new("a" => CA_INT32([1]), "t1" => CA_INT32([2]), "t2" => CA_INT32([3]),
                "b" => CA_INT32([4]), "t3" => CA_INT32([5]))
  end

  def test_select
    assert_equal %w[t1 t2 b], frame.select("t1".."b").column_names
    assert_equal %w[t1 t2], frame.select("t1"..."b").column_names
    assert_equal %w[t1 t2 t3], frame.select(/^t/).column_names
    assert_equal %w[b t1 t2], frame.select("b", "t1".."t2").column_names
  end

  def test_drop
    assert_equal %w[a b], frame.drop(/^t/).column_names
    assert_equal %w[a t3], frame.drop("t1".."b").column_names
  end

  def test_refusals
    assert_raise(ArgumentError) { frame.select("t1", /^t/) }      # t1 twice
    assert_raise(ArgumentError) { frame.select(/^z/) }            # selects nothing
    assert_raise(ArgumentError) { frame.drop("b".."t1") }         # backwards
    assert_raise(KeyError) { frame.select("a".."zz") }
    assert_raise(TypeError) { frame.select(:a) }
  end
end
