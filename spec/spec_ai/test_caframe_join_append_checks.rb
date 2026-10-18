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

  # The only column is held to N too, as df[name] = holds it.
  def test_replacing_the_only_column_keeps_the_length
    one = CAFrame.new("a" => CA_INT64([1, 2, 3]))
    assert_raise(ArgumentError) { one.append("a", CA_INT64([1, 2])) }
    assert_raise(ArgumentError) { one.append("a", CA_INT64([1, 2]), after: "a") }
    assert_equal 2, CAFrame.new({}).append("a", CA_INT32([1, 2])).nrow
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

class TestJoinIndexNameCollision < Test::Unit::TestCase

  def left
    CAFrame.new({ "k" => CA_INT64([1, 2, 3]) }, axis_name: "name",
                index: CA_OBJECT(%w[a b c]))
  end

  def right
    CAFrame.new("k" => CA_INT64([2, 5]), "name" => CA_OBJECT(%w[x y]))
  end

  # The left index keeps its name; the right column takes the right suffix.
  def test_a_right_column_named_as_the_left_index_takes_the_suffix
    %i[left inner outer right].each do |how|
      df = left.join(right, on: "k", how: how)
      assert_equal %w[k name_right], df.column_names, how.inspect
      assert_equal "name", df.axis_name
    end
    assert_equal %w[k name_right], left.join_asof(right, on: "k").column_names
    assert_raise(ArgumentError) { left.join(right, on: "k", suffixes: false) }
  end

  def test_paste_does_the_same
    l = CAFrame.new({ "v" => CA_INT32([1, 2]) }, axis_name: "name", index: CA_INT32([1, 2]))
    r = CAFrame.new("name" => CA_INT32([3, 4]))
    assert_equal %w[v name_right], l.paste(r).column_names
  end
end

class TestOuterJoinKeyKind < Test::Unit::TestCase

  def outer(l, r)
    CAFrame.new("k" => l, "v" => CA_INT32([1, 2]))
           .join(CAFrame.new("k" => r, "w" => CA_INT32([3, 4])), on: "k", how: :outer)["k"]
  end

  def test_a_shared_categorical_stays_with_the_labels_of_both
    k = outer(CA_OBJECT(%w[a b]).categorize, CA_OBJECT(%w[b c]).categorize(labels: %w[z b c]))
    assert_kind_of CACategorical, k
    assert_equal %w[a b z c], k.labels
    assert_equal %w[a b c], k.to_a
  end

  def test_a_shared_const_string_stays
    assert_kind_of CAConstString, outer(CArray.const_string(%w[a b]), CArray.const_string(%w[b c]))
  end

  # Different kinds give an object column, whichever side is the receiver.
  def test_different_kinds_are_objects_either_way
    c = -> { CArray.const_string(%w[a b]) }
    o = -> { CA_OBJECT(%w[b c]) }
    [outer(c.(), o.()), outer(o.(), c.())].each do |k|
      assert_instance_of CArray, k
      assert_equal :object, k.data_type
    end
    k = outer(CA_OBJECT(%w[a b]).categorize, CA_OBJECT(%w[b c]))
    assert_instance_of CArray, k
  end
end
