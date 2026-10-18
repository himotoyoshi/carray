$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

class TestJoinAsofByChecksItsOptions < Test::Unit::TestCase

  def frames
    l = CAFrame.new("x" => CA_FLOAT64([1, 2]), "g" => CA_INT64([1, 1]))
    r = CAFrame.new("x" => CA_FLOAT64([1, 2]), "g" => CA_INT64([9, 9]),
                    "w" => CA_INT64([5, 6]))
    [l, r]
  end

  # No group is in both frames, so no group reaches the search.
  def test_direction_is_checked_without_a_shared_group
    l, r = frames
    assert_raise(ArgumentError) { l.join_asof(r, on: "x", by: "g", direction: :bogus) }
  end

  def test_tolerance_is_checked_without_a_shared_group
    l, r = frames
    assert_raise(ArgumentError) { l.join_asof(r, on: "x", by: "g", tolerance: "10 minutes") }
  end

end

class TestAppendChecksItsArguments < Test::Unit::TestCase

  def two
    CAFrame.new("a" => CA_INT64([1, 2, 3]), "b" => CA_INT64([4, 5, 6]))
  end

  def test_a_replacing_column_of_another_length_is_named
    err = assert_raise(ArgumentError) { two.append("a", CA_INT64([1, 2]), before: "a") }
    assert_match(/"a"/, err.message)
    err = assert_raise(ArgumentError) { two.append("a", CA_INT64([1, 2])) }
    assert_match(/"a"/, err.message)
  end

  def test_the_index_is_a_witness_of_the_length
    df = CAFrame.new({ "a" => CA_INT64([1, 2, 3]) }, index: CA_INT64([7, 8, 9]))
    err = assert_raise(ArgumentError) { df.append("a", CA_INT64([1, 2])) }
    assert_match(/"a"/, err.message)
  end

  def test_before_and_after_read_false_alike
    x = CA_INT64([7, 8, 9])
    assert_raise(TypeError) { two.append("c", x, before: false) }
    assert_raise(TypeError) { two.append("c", x, after: false) }
    assert_raise(ArgumentError) { two.append("c", x, before: "a", after: false) }
  end

  def test_before_and_after_place_the_column
    x = CA_INT64([7, 8, 9])
    assert_equal %w[c a b], two.append("c", x, before: "a").column_names
    assert_equal %w[a c b], two.append("c", x, after: "a").column_names
  end

end
