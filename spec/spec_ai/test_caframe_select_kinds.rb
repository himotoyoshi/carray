# frozen_string_literal: true

require "test/unit"
require "carray"

# select / drop / transform take a Symbol for the columns of a kind, or of a
# data type as cast names it.
class TestCAFrameSelectKinds < Test::Unit::TestCase
  def frame
    CAFrame.new("t"  => CArray.time(%w[2024-01-01 2024-01-02]),
                "s"  => CArray.string(%w[a b]),
                "o"  => CA_OBJECT(%w[x y]),
                "oi" => CA_OBJECT([1, 2]),
                "i"  => CA_INT32([1, 2]),
                "f"  => CA_FLOAT64([1, 2]),
                "z"  => CA_CMPLX128([1, 2]),
                "b"  => CA_BOOLEAN([true, false]),
                "c"  => CA_OBJECT(%w[a b]).categorize,
                "fx" => CArray.fixlen_string(%w[ab cd]),
                "cs" => CArray.const_string(%w[p q]))
  end

  def test_kinds
    df = frame
    assert_equal %w[i f z], df.select(:numeric).column_names
    assert_equal %w[s o fx cs], df.select(:string).column_names
    assert_equal %w[t], df.select(:time).column_names
    assert_equal %w[c], df.select(:categorical).column_names
  end

  def test_data_types
    df = frame
    assert_equal %w[f], df.select(:float64).column_names
    assert_equal %w[i], df.select(:int32).column_names
    assert_equal %w[b], df.select(:boolean).column_names
    assert_equal %w[o oi], df.select(:object).column_names   # a Face is not its storage type
  end

  def test_an_object_column_of_strings_needs_every_present_cell_to_be_one
    o = CA_OBJECT(["a", nil])
    o[1] = UNDEF
    df = CAFrame.new("o" => o, "m" => CA_OBJECT(["a", 1]))
    assert_equal %w[o], df.select(:string).column_names
  end

  def test_with_names_drop_and_transform
    df = frame
    assert_equal %w[t i f z], df.select("t", :numeric).column_names
    assert_equal %w[t oi i f z b c], df.drop(:string).column_names
    out = df.transform(:numeric) { |col| col * 2 }
    assert_equal [2, 4], out["i"].to_a
    assert_equal %w[a b], out["s"].to_a
    assert_equal :float64, df.select(:numeric, :boolean).drop(:cmplx128).to_ca.data_type
  end

  def test_describe_picks_columns_as_select_does
    df = frame
    assert_equal %w[i f z], df.describe(:numeric).index.to_a
    assert_equal %w[t s o], df.describe("t".."o").index.to_a
  end

  def test_refusals
    df = frame
    assert_raise(ArgumentError) { df.select(:uint8) }                 # no such column
    assert_raise(ArgumentError) { CAFrame.new("s" => CArray.string(%w[a])).select(:numeric) }
    e = assert_raise(TypeError) { df.select(:station) }
    assert_match(/a Symbol names a kind of column/, e.message)
    assert_raise(ArgumentError) { df.select(:numeric, "i") }          # i twice
  end
end
