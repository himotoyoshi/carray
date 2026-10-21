# frozen_string_literal: true
#
# A frame-wide verb over the columns -- a group reduction, a group transform,
# a windowed reduction -- answers in one shape (CAFrame::ColumnVerbs):
# without names, a frame of every column whose type has it, the key columns
# left out; with names, a verb whose answers lie on the frame's rows gives
# the CArray (one) or the Array (several) as df[...] returns columns, a
# group reduction (one row per group) the frame of those columns with the
# group labels; a named column whose type lacks it is refused with
# CArray::DataTypeError.  An N-D column (each row a profile) is computed
# along the rows and keeps its trailing shape.
#
# Before, each verb kept its own copy of this: a window left an N-D column
# out of the frame and refused it by name ("has no windowed sum") where a
# group computed it, a named group reduction refused with ArgumentError and
# a named transform with the core's DataTypeError.

require "test/unit"
require "carray"
require "carray/frame"

class TestFrameColumnVerbs < Test::Unit::TestCase

  def frame
    CAFrame.new("k"    => CA_INT32([0, 0, 1, 1]),
                "t"    => CA_DOUBLE([0, 1, 2, 3]),
                "v"    => CA_DOUBLE([1, 2, 3, 4]),
                "p"    => CArray.float64(4, 2) { |i, j| i * 10 + j },
                "name" => CA_OBJECT(%w[a b c d]))
  end

  VERBS = {
    "group sum"    => ->(df, *n) { df.group_by("k").sum(*n) },
    "group mean"   => ->(df, *n) { df.group_by("k").mean(*n) },
    "group cumsum" => ->(df, *n) { df.group_by("k").cumsum(*n) },
    "window sum"   => ->(df, *n) { df.windows(on: "t", before: 1.5).sum(*n) },
    "window mean"  => ->(df, *n) { df.windows(on: "t", before: 1.5).mean(*n) },
  }.freeze

  def test_without_names_every_column_that_has_it
    VERBS.each do |label, verb|
      out = verb.(frame)
      assert_kind_of CAFrame, out, label
      assert_include out.column_names, "v", label
      assert_include out.column_names, "p", label           # an N-D column too
      assert_not_include out.column_names, "name", label    # an object column of strings has no sum or mean
      assert_not_include out.column_names, "k", label if label.start_with?("group")
      assert_equal [2], out["p"].shape[1..], label
    end
  end

  def test_with_names_as_df_returns_columns
    VERBS.each do |label, verb|
      if label.start_with?("group") && label != "group cumsum"
        one = verb.(frame, "p")
        assert_kind_of CAFrame, one, label
        assert_equal ["p"], one.column_names, label
        assert_equal [2, 2], one["p"].shape, label
        assert_equal %w[v p], verb.(frame, "v", "p").column_names, label
        next
      end
      one = verb.(frame, "p")
      assert_kind_of CArray, one, label
      assert_equal 2, one.ndim, label
      two = verb.(frame, "v", "p")
      assert_kind_of CAFrame, two, label
      assert_equal %w[v p], two.column_names, label
      assert_equal frame.nrow, two.nrow, label
    end
  end

  def test_a_named_column_without_it_is_a_data_type_error
    VERBS.each do |label, verb|
      e = assert_raise(CArray::DataTypeError, label) { verb.(frame, "name") }
      assert_match(/\A\w+: column "name" \(object\) has no \w+\z/, e.message, label)
    end
  end

  def test_a_window_reduces_a_profile_column_along_the_rows
    df = frame
    got = df.windows(on: "t", before: 1.5).sum("p")
    2.times do |j|
      col = CAFrame.new("t" => df["t"], "c" => df["p"][nil, j].copy)
      assert_equal col.windows(on: "t", before: 1.5).sum("c").to_a, got[nil, j].to_a
    end
  end

end
