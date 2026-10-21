# frozen_string_literal: true

require "test/unit"
require "carray"

# The index's name: a key reads the index, a column does not; rename
# renames the index as it renames a column.
class TestCAFrameIndexName < Test::Unit::TestCase
  def summary
    df = CAFrame.new("shop" => CA_OBJECT(%w[n s n s]), "v" => CA_FLOAT64([1, 2, 3, 4]))
    return df.group_by("shop").sum("v")
  end

  def test_rename_renames_the_index
    s   = summary
    out = s.rename("shop" => "store")
    assert_equal "store", out.axis_name
    assert_equal %w[n s], out.index.to_a
    assert_equal %w[v], out.column_names
    assert_equal "shop", s.axis_name                       # the receiver as it was
    assert_equal %w[store v], out.reset_index.column_names
  end

  def test_rename_with_a_block_is_given_the_index_too
    out = summary.rename { |name| name.upcase }
    assert_equal "SHOP", out.axis_name
    assert_equal %w[V], out.column_names
  end

  def test_rename_exchanges_a_column_and_the_index
    out = summary.rename("shop" => "v", "v" => "shop")
    assert_equal "v", out.axis_name
    assert_equal %w[shop], out.column_names
  end

  def test_rename_refusals
    s = summary
    assert_raise(ArgumentError) { s.rename("shop" => "v") }
    assert_raise(ArgumentError) { s.rename("v" => "shop") }
    df = CAFrame.new("v" => CA_FLOAT64([1]))
    e = assert_raise(KeyError) { df.rename("row" => "x") }       # no index, no name to rename
    assert_equal 'rename: no column "row"', e.message
  end

  # Where a verb takes columns, the index's name is refused pointing at
  # df.index; where it takes a key, the name reaches the index.
  def test_a_key_reads_the_index_and_a_column_does_not
    s = summary
    [-> { s["shop"] }, -> { s.select("shop") }, -> { s.drop("shop") },
     -> { s.cast("shop" => :string) }, -> { s.melt(id: "shop") },
     -> { s.mean("shop") }, -> { s.select("shop".."v") }].each do |call|
      e = assert_raise(KeyError) { call.() }
      assert_match(/it is the index, read it with df\.index/, e.message)
    end
    assert_equal %w[n s], s.sort_by_key("shop").index.to_a
    assert_equal 2, s.group_by("shop").sum.nrow
  end
end
