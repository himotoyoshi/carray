# frozen_string_literal: true
#
# Column names a frame verb makes or takes, none of them twice
# (CAFrame.refuse_repeated_names): ArgumentError "<verb>: <what> <name> more
# than once".  A frame holds one column per name, so a repeated name among
# new columns would keep only the last of them, and among the columns a verb
# takes it would be taken once or twice depending on the verb.  df[...]
# alone takes a name twice, as Hash#values_at does.
#
# Before, eleven checks wrote this each in their own words, and the verbs
# that take columns did not check at all: select("a", "a") gave one column,
# group_by / sort_by_key / is_duplicate took the name as if once, and
# drop("a", "a") raised KeyError on the second.

require "test/unit"
require "carray"
require "carray/frame"
require "tempfile"

class TestFrameRepeatedNames < Test::Unit::TestCase

  def df
    CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([3, 4]),
                "s" => CA_OBJECT(["x-y", "z-w"]), "p" => CArray.int32(2, 2).seq)
  end

  def assert_repeated (verb, what, name, &block)
    e = assert_raise(ArgumentError, verb) { block.call }
    assert e.message.start_with?("#{verb}: #{what} #{name.inspect} more than once"), e.message
  end

  def test_the_verbs_that_take_columns
    %w[select drop group_by sort_by_key is_duplicate describe].each do |verb|
      assert_repeated(verb, "names", "a") { df.public_send(verb, "a", "a") }
    end
    assert_repeated("join", "on: names", "a") { df.join(df, on: %w[a a]) }
    assert_repeated("melt", "names", "a") { df.melt(id: %w[a a]) }
  end

  def test_the_verbs_that_make_columns
    assert_repeated("to_frame", "names", "x") { CArray.int32(2, 2).to_frame("x", "x") }
    assert_repeated("split_column", "into: names", "q") { df.split_column("s", "-", into: %w[q q]) }
    assert_repeated("unstack_column", "into: names", "q") { df.unstack_column("p", into: %w[q q]) }
    assert_repeated("from_records", "the keys name the column", "t") { CAFrame.from_records([{ "t" => 1, t: 2 }]) }
  end

  def test_a_csv
    Tempfile.create(["d", ".csv"]) do |f|
      f.write("a,b,a\n1,2,3\n"); f.flush
      assert_repeated("from_csv", "the header row names", "a") { CAFrame.from_csv(f.path) }
    end
    Tempfile.create(["d", ".csv"]) do |f|
      f.write("a,b,c\n1,2,3\n"); f.flush
      assert_repeated("from_csv", "columns: names", "z") { CAFrame.from_csv(f.path, columns: { "a" => "z", "b" => "z" }) }
      assert_repeated("from_csv", "columns: selects column", 0) { CAFrame.from_csv(f.path, columns: [0, 0]) }
    end
  end

  def test_df_brackets_take_a_name_twice
    assert_equal 2, df["a", "a"].size
  end

end
