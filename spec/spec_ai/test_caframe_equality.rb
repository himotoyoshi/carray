# frozen_string_literal: true

require "test/unit"
require "carray"

# CAFrame#== compares the table: names, columns (as CArray#==), index and
# row axis name; not the attributes.
class TestCAFrameEquality < Test::Unit::TestCase
  def frame
    v = CA_FLOAT64([1, 2, 3])
    v[1] = UNDEF
    CAFrame.new({ "k" => CArray.string(%w[a b c]), "v" => v },
                axis_name: "t", index: CArray.time(%w[2024-01-01 2024-01-02 2024-01-03]))
  end

  def test_equal_tables
    df = frame
    assert_equal df, df.copy
    assert_equal df, frame
    other = df.copy
    other.set_attr("title", "x")
    assert_equal df, other               # attributes are not compared
  end

  def test_masked_cells_compare_by_where_they_are
    v1 = CA_FLOAT64([1, 2, 3])
    v2 = CA_FLOAT64([1, 99, 3])          # the value under the mask differs
    v1[1] = UNDEF
    v2[1] = UNDEF
    assert_equal CAFrame.new("v" => v1), CAFrame.new("v" => v2)
    v2[1] = 2.0
    assert_not_equal CAFrame.new("v" => v1), CAFrame.new("v" => v2)
  end

  def test_differences
    df = frame
    assert_not_equal df, df.cast("v" => :float32)          # data type
    assert_not_equal df, df.rename("v" => "w")             # names
    assert_not_equal df, df.select("v", "k")               # order
    assert_not_equal df, df.reset_index                    # index
    assert_not_equal df, df.head(2)                        # rows
    c = df.copy
    c["k"][0] = "z"
    assert_not_equal df, c                                 # a value
    assert_not_equal df, 1
  end

  def test_pivot_error_shows_a_time_as_it_reads
    df = CAFrame.new("d" => CArray.time(%w[2024-01-01 2024-01-01]),
                     "s" => CArray.string(%w[A A]), "v" => CA_FLOAT64([1, 2]))
    e = assert_raise(ArgumentError) { df.pivot(index: "d", columns: "s", values: "v") }
    assert_match(/d=2024-01-01, s="A"/, e.message)
  end
end
