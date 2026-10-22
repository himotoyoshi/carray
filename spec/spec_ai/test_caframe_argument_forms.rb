# frozen_string_literal: true

require "test/unit"
require "carray"

# The forms the frame's verbs take their arguments in: what df[] says about
# a Ruby Array, column names given as an Array, fill over several or every
# column, and sort_by(descending:).
class TestCAFrameArgumentForms < Test::Unit::TestCase
  def frame
    a = CA_FLOAT64([1, 2, 3, 4])
    a[1] = UNDEF
    b = CA_FLOAT64([5, 6, 7, 8])
    b[2] = UNDEF
    CAFrame.new("g" => CA_OBJECT(%w[x y x y]), "a" => a, "b" => b,
                "s" => CArray.string(%w[bb a ccc dd]))
  end

  def test_df_with_a_ruby_array_says_what_to_write
    df = frame
    e = assert_raise(ArgumentError) { df[[0, 2]] }
    assert_match(/df\[CA_INT64\(\[0, 2\]\)\]/, e.message)
    e = assert_raise(ArgumentError) { df[[true, false, true, false]] }
    assert_match(/CA_BOOLEAN/, e.message)
    e = assert_raise(ArgumentError) { df[%w[a b]] }
    assert_match(/df\["a", "b"\] or df\.select\("a", "b"\)/, e.message)
    e = assert_raise(ArgumentError) { df[:a] }
    assert_match(/df\["a"\]/, e.message)
  end

  def test_names_given_as_an_array
    df = frame
    assert_equal %w[a b], df.select(%w[a b]).column_names
    assert_equal %w[g s], df.drop(%w[a b]).column_names
    assert_equal 2, df.drop_masked(%w[a b]).nrow
  end

  def test_fill_several_columns_one_way
    df = frame
    assert_same df, df.fill("a", "b", :ffill)
    assert_equal [1.0, 1.0, 3.0, 4.0], df["a"].to_a
    assert_equal [5.0, 6.0, 6.0, 8.0], df["b"].to_a
    df = frame
    df.fill(:numeric, 0)
    assert_equal [1.0, 0.0, 3.0, 4.0], df["a"].to_a
    df = frame
    df.fill(%w[a b], -1.0)
    assert_equal [5.0, 6.0, -1.0, 8.0], df["b"].to_a
  end

  def test_fill_every_column_with_a_masked_cell
    df = frame
    df.fill(:linear)
    assert_equal [1.0, 2.0, 3.0, 4.0], df["a"].to_a
    assert_equal [5.0, 6.0, 7.0, 8.0], df["b"].to_a
    df = CAFrame.new("a" => CA_FLOAT64([1, 2]))
    assert_same df, df.fill(0.0)                  # nothing masked
  end

  def test_fill_checks_every_column_before_filling
    df = frame
    df["s"][0] = UNDEF
    assert_raise(ArgumentError) { df.fill("a", "s", :linear) }
    assert_equal 1, df["a"].count_masked
  end

  def test_group_fill_forms
    df = frame
    df.group_by("g").fill("a", "b", :ffill)
    assert_equal [1.0, UNDEF, 3.0, 4.0], df["a"].to_a     # nothing before it in group y
    assert_equal [5.0, 6.0, 5.0, 8.0], df["b"].to_a
    df = frame
    df.group_by("g").fill(:bfill)
    assert_equal [1.0, 4.0, 3.0, 4.0], df["a"].to_a
  end

  def test_fill_refusals
    df = frame
    e = assert_raise(ArgumentError) { df.fill("a") }
    assert_match(/after the column "a"/, e.message)
    assert_raise(ArgumentError) { df.fill }
    assert_raise(ArgumentError) { df.fill({}) }
    assert_raise(ArgumentError) { df.fill({ "a" => 0.0 }, 1.0) }
    assert_raise(ArgumentError) { df.fill("a", "b", :sideways) }
  end

  # A group key named in a reduction is refused by name; count points at size.
  def test_a_group_key_named_in_a_reduction
    grp = frame.group_by("g")
    e = assert_raise(ArgumentError) { grp.count("g") }
    assert_match(/"g" is the group key.*size/, e.message)
    assert_raise(ArgumentError) { grp.max("g", "a") }
    assert_equal [2, 2, 2, 2], grp.count("g", keep_rows: true).to_a
    assert_equal [2, 2], grp.size["size"].to_a
  end

  def test_the_first_and_last_rows_of_each_group
    k = CA_OBJECT(%w[a b a b a c])
    k[5] = UNDEF
    grp = CAFrame.new("k" => k, "v" => CA_INT32([0, 1, 2, 3, 4, 5])).group_by("k")
    assert_equal [0, 1], grp.head(1)["v"].to_a
    assert_equal [0, 1, 2, 3], grp.head(2)["v"].to_a
    assert_equal [3, 4], grp.tail(1)["v"].to_a
    assert_equal [0, 1, 2, 3, 4], grp.head["v"].to_a     # the row in no group left out
    assert_equal 0, grp.head(0).nrow
    assert_raise(ArgumentError) { grp.head(-1) }
    assert_raise(TypeError) { grp.tail("1") }
  end

  # == in a condition compares whole arrays and gives true or false; the
  # refusal says to use eq.
  def test_a_condition_written_with_equals
    df = frame
    e = assert_raise(ArgumentError) { df.filter { |f| f["g"] == "x" } }
    assert_match(/eq and ne compare cell by cell/, e.message)
    e = assert_raise(ArgumentError) { df.group_by("g").filter { |g| g.mean("a")["a"] == 1 } }
    assert_match(/eq and ne/, e.message)
    e = assert_raise(ArgumentError) { df.verify("x" => ->(f) { f["g"] != "x" }) }
    assert_match(/eq and ne/, e.message)
    e = assert_raise(ArgumentError) { df.filter { |f| f["g"].to_a } }
    assert_no_match(/eq and ne/, e.message)
  end

  def test_csv_text_given_as_a_path
    e = assert_raise(Errno::ENOENT) { CAFrame.read_csv("a,b\n1,2\n") }
    assert_match(/from_csv\(text\)/, e.message)
    assert_equal %w[a b], CAFrame.from_csv("a,b\n1,2\n").column_names
  end

  def test_aggregate_with_reductions_in_the_column_place
    grp = frame.group_by("g")
    e = assert_raise(ArgumentError) { grp.aggregate("a" => [:sum, :mean]) }
    assert_match(/result name => \[column, reduction\]/, e.message)
  end

  def test_sort_by_descending
    df = frame
    assert_equal %w[dd ccc bb a], df.sort_by(descending: true) { |f| f["s"] }["s"].to_a
    assert_equal [4.0, 3.0, 1.0, UNDEF], df.sort_by(descending: true) { |f| f["a"] }["a"].to_a
    assert_equal [UNDEF, 4.0, 3.0, 1.0],
                 df.sort_by(descending: true, masked_position: :first) { |f| f["a"] }["a"].to_a
  end
end
