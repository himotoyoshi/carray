# frozen_string_literal: true
#
# A key a CAFrame verb takes is read by one part, CAFrame#key_column: a
# column of that name, or the index by the row axis name, or a CArray; one
# value per row, an N-D key refused with ArgumentError "<verb>: the key "p"
# has shape [...], not one value per row; use one of its components".
#
# Before, each verb read its keys itself: join and join_asof could not take
# the index (KeyError: no column), and an N-D key was refused in five
# wordings, the windows one telling the user to "group by" a component.
# join on the index keeps it once: the left index is the result's index,
# and an unmatched right row of an outer or right join takes its key from
# the right, as a key column does.

require "test/unit"
require "carray"
require "carray/frame"

class TestFrameKeys < Test::Unit::TestCase

  def df
    CAFrame.new({ "v" => CA_INT32([1, 2, 1]), "p" => CArray.int32(3, 2).seq,
                  "t" => CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D) },
                axis_name: "id", index: CA_OBJECT(%w[a b a]))
  end

  def right ; CAFrame.new("id" => CA_OBJECT(%w[b c]), "w" => CA_INT32([20, 30])) ; end

  def test_the_index_is_a_key_wherever_a_key_is_taken
    assert_equal 2, df.group_by("id").sum.nrow
    assert_equal [false, false, true], df.is_duplicate("id").to_a
    assert_equal %w[a a b], df.sort_by_key("id").index.to_a
    assert_equal 3, df.join(right, on: "id").nrow
    assert_equal 3, df.join_asof(right, on: "id").nrow
    assert_equal 3, df.windows(on: "t", before: "1 day", by: "id").sum.nrow
  end

  def test_a_join_on_the_index_keeps_the_key_once
    l = CAFrame.new({ "v" => CA_INT32([1, 2]) }, axis_name: "id", index: CA_OBJECT(%w[a b]))
    { left: %w[a b], inner: %w[b], outer: %w[a b c], right: %w[b c] }.each do |how, index|
      j = l.join(right, on: "id", how: how)
      assert_equal index, j.index.to_a, how.to_s
      assert_equal %w[v w], j.column_names, how.to_s
    end
  end

  def test_an_nd_key_is_refused_in_one_wording
    {
      "group_by"     => -> { df.group_by("p") },
      "is_duplicate" => -> { df.is_duplicate("p") },
      "sort_by_key"  => -> { df.sort_by_key("p") },
      "join"         => -> { df.join(df, on: "p") },
      "windows"      => -> { df.windows(on: "p", before: 1) },
      "pivot"        => -> { df.pivot(index: "p", columns: "v", values: "v") },
    }.each do |verb, call|
      e = assert_raise(ArgumentError, verb) { call.() }
      assert_equal "#{verb}: the key \"p\" has shape [3, 2], not one value per row; " \
                   "use one of its components (e.g. df[name][nil, 0])", e.message
    end
  end

end
