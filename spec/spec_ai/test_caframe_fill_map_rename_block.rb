# frozen_string_literal: true

require "test/unit"
require "carray"

# fill takes a Hash of column => method or value; rename takes a block, and
# refuses two columns ending up with one name.
class TestCAFrameFillMapRenameBlock < Test::Unit::TestCase
  def frame
    t = CA_FLOAT64([1, 0, 3, 4])
    t[1] = UNDEF
    w = CA_FLOAT64([5, 0, 0, 8])
    w[1] = UNDEF
    w[2] = UNDEF
    CAFrame.new("k" => CA_OBJECT(%w[a a b b]), "t" => t, "w" => w)
  end

  def test_fill_a_hash
    df = frame
    assert_same df, df.fill("t" => :linear, "w" => 0.0)
    assert_equal [1.0, 2.0, 3.0, 4.0], df["t"].to_a
    assert_equal [5.0, 0.0, 0.0, 8.0], df["w"].to_a
  end

  def test_fill_a_hash_is_checked_before_filling
    df = frame
    assert_raise(ArgumentError) { df.fill("t" => 0.0, "w" => :sideways) }
    assert_raise(KeyError) { df.fill("t" => 0.0, "nope" => 1) }
    assert_equal 1, df["t"].count_masked
    assert_raise(ArgumentError) { df.fill({}) }
    assert_raise(ArgumentError) { df.fill("t") }
    assert_raise(ArgumentError) { df.fill({ "t" => 0.0 }, 1.0) }
  end

  def test_fill_a_hash_writes_nothing_when_a_column_is_refused
    df = frame.append("s", CA_OBJECT(["x", nil, "z", "w"]))
    df["s"][1] = UNDEF
    assert_raise(ArgumentError) { df.fill("t" => 0.0, "s" => :linear) }   # s is text
    assert_equal 1, df["t"].count_masked
    assert_raise(ArgumentError) { df.group_by("k").fill("t" => :ffill, "s" => :linear) }
    assert_equal 1, df["t"].count_masked
    ro = CAFrame.new("v" => CA_FLOAT64([1, 0]), "u" => CA_FLOAT64([0, 2]))
    ro["v"][1] = UNDEF
    ro["u"][0] = UNDEF
    part = ro.protect.select("v", "u")
    assert_raise(RuntimeError) { part.fill("v" => 0.0, "u" => 0.0) }
    assert_equal [1.0, UNDEF], ro["v"].to_a
  end

  def test_grouped_fill_a_hash
    df = frame
    df.group_by("k").fill("t" => :ffill, "w" => :bfill)
    assert_equal [1.0, 1.0, 3.0, 4.0], df["t"].to_a
    assert_equal [5.0, UNDEF, 8.0, 8.0], df["w"].to_a
  end

  def test_rename_with_a_block
    assert_equal %w[K T W], frame.rename { |name| name.upcase }.column_names
    assert_equal %w[k t w], frame.rename { |name| name }.column_names
  end

  def test_rename_exchanges_names
    df = frame
    out = df.rename("t" => "w", "w" => "t")
    assert_equal %w[k w t], out.column_names
    assert_same df["t"], out["w"]
  end

  def test_rename_refusals
    assert_raise(ArgumentError) { frame.rename("t" => "x", "w" => "x") }
    assert_raise(ArgumentError) { frame.rename("t" => "w") }
    assert_raise(ArgumentError) { frame.rename { |_| "same" } }
    assert_raise(TypeError) { frame.rename { |name| name.to_sym } }
    assert_raise(ArgumentError) { frame.rename }
    assert_raise(ArgumentError) { frame.rename("t" => "x") { |n| n } }
  end
end
