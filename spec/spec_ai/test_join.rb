# ----------------------------------------------------------------------------
#
#  spec_ai/test_join.rb
#
#  Tests for CArray#join.  Two forms share one entry point:
#
#    a.join(sep = nil)                     — flat, returns String
#    a.join(sep = "", axis:, keep_axis:)   — per-axis, returns CArray (or
#                                            String when self is 1-D)
#
#  The 2.x multi-separator form (`a.join("\n", ",")`) was removed in 3.0;
#  the same output is now written as `a.join(",", axis: 1).join("\n")`.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestJoin < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # flat form (unchanged from 2.x)
  # ------------------------------------------------------------------

  def test_flat_no_sep
    a = CArray.int32(3, 3).seq
    assert_equal "012345678", a.join
  end

  def test_flat_with_sep
    a = CArray.int32(3, 3).seq
    assert_equal "0,1,2,3,4,5,6,7,8", a.join(",")
  end

  def test_flat_1d
    assert_equal "1,2,3", CA_INT32([1, 2, 3]).join(",")
  end

  # ------------------------------------------------------------------
  # multi-separator removal (3.0 breaking)
  # ------------------------------------------------------------------

  def test_multi_sep_raises
    a = CArray.int32(3, 3).seq
    assert_raise(ArgumentError) { a.join("\n", ",") }
    assert_raise(ArgumentError) { a.join(",", " ", "|") }
  end

  # ------------------------------------------------------------------
  # per-axis form
  # ------------------------------------------------------------------

  def test_axis_1_2d
    a = CArray.int32(3, 3).seq
    r = a.join(" ", axis: 1)
    assert_kind_of CArray, r
    assert_equal [3], r.shape
    assert_equal ["0 1 2", "3 4 5", "6 7 8"], r.to_a
  end

  def test_axis_0_2d
    a = CArray.int32(3, 3).seq
    r = a.join(",", axis: 0)
    assert_equal [3], r.shape
    assert_equal ["0,3,6", "1,4,7", "2,5,8"], r.to_a
  end

  def test_axis_default_sep_empty
    # Matches Ruby Array#join default.
    a = CArray.int32(3, 3).seq
    r = a.join(axis: 1)
    assert_equal ["012", "345", "678"], r.to_a
  end

  def test_axis_negative
    a = CArray.int32(3, 3).seq
    assert_equal a.join(",", axis: 1).to_a,
                 a.join(",", axis: -1).to_a
  end

  def test_axis_out_of_range
    a = CArray.int32(3, 3).seq
    assert_raise(ArgumentError) { a.join(",", axis: 5) }
    assert_raise(ArgumentError) { a.join(",", axis: -5) }
  end

  def test_axis_3d_innermost
    b = CArray.int32(2, 3, 4).seq
    r = b.join(",", axis: 2)
    assert_equal [2, 3], r.shape
    assert_equal "0,1,2,3", r[0, 0]
    assert_equal "20,21,22,23", r[1, 2]
  end

  def test_axis_3d_middle
    b = CArray.int32(2, 3, 4).seq
    r = b.join(",", axis: 1)
    assert_equal [2, 4], r.shape
    # Fiber b[0, :, 0] = [0, 4, 8]
    assert_equal "0,4,8", r[0, 0]
    # Fiber b[1, :, 3] = [15, 19, 23]
    assert_equal "15,19,23", r[1, 3]
  end

  def test_axis_1d_returns_string
    r = CA_INT32([1, 2, 3]).join(",", axis: 0)
    assert_equal "1,2,3", r
    assert_kind_of String, r
  end

  def test_axis_1d_keep_axis
    r = CA_INT32([1, 2, 3]).join(",", axis: 0, keep_axis: true)
    assert_kind_of CArray, r
    assert_equal [1], r.shape
    assert_equal ["1,2,3"], r.to_a
  end

  def test_axis_keep_axis_2d
    a = CArray.int32(3, 3).seq
    r = a.join(",", axis: 1, keep_axis: true)
    assert_equal [3, 1], r.shape
    assert_equal [["0,1,2"], ["3,4,5"], ["6,7,8"]], r.to_a
  end

  # ------------------------------------------------------------------
  # chain composition (the point of the redesign)
  # ------------------------------------------------------------------

  def test_chain_to_string_via_flat_join
    a = CArray.int32(3, 3).seq
    result = a.join(" ", axis: 1).join("\n")
    assert_equal "0 1 2\n3 4 5\n6 7 8", result
  end

  def test_chain_axis_then_axis
    a = CArray.int32(3, 3).seq
    result = a.join(",", axis: 1).join("\n", axis: 0)
    assert_equal "0,1,2\n3,4,5\n6,7,8", result
  end

  def test_chain_3d_full_reduction
    b = CArray.int32(2, 3, 4).seq
    result = b.join(",", axis: 2).join(" | ", axis: 1).join("\n")
    lines = result.split("\n")
    assert_equal 2, lines.size
    assert_equal "0,1,2,3 | 4,5,6,7 | 8,9,10,11", lines[0]
    assert_equal "12,13,14,15 | 16,17,18,19 | 20,21,22,23", lines[1]
  end

  # ------------------------------------------------------------------
  # dtype coverage
  # ------------------------------------------------------------------

  def test_axis_float
    a = CArray.float64(2, 2) { |i, j| i + 0.5 * j }
    r = a.join(",", axis: 1)
    assert_equal ["0.0,0.5", "1.0,1.5"], r.to_a
  end

  def test_axis_object
    a = CArray.object(2, 3).seq("a", :succ)
    r = a.join(",", axis: 1)
    assert_equal ["a,b,c", "d,e,f"], r.to_a
  end

end
