# CAFrame#fill — mask gap-fill delegate (memo §6 / §11.8).

require "test/unit"
require "carray"
require "carray/categorical"

class TestCAFrameFill < Test::Unit::TestCase

  def col(vals, *masked)
    c = CA_FLOAT64(vals)
    masked.each { |i| c[i] = UNDEF }
    c
  end

  def test_ffill_in_place_returns_self
    df = CAFrame.new("temp" => col([22.1, 25.3, 0, 0], 2, 3))
    r = df.fill("temp", :ffill)
    assert_same(df, r)
    assert_equal([22.1, 25.3, 25.3, 25.3], df["temp"].to_a)
  end

  def test_bfill
    df = CAFrame.new("temp" => col([22.1, 25.3, 0, 0], 2, 3))
    df.fill("temp", :bfill)
    assert_equal([22.1, 25.3, UNDEF, UNDEF], df["temp"].to_a)
  end

  def test_constant
    df = CAFrame.new("temp" => col([22.1, 25.3, 0, 0], 2, 3))
    df.fill("temp", 0.0)
    assert_equal([22.1, 25.3, 0.0, 0.0], df["temp"].to_a)
  end

  def test_linear_uses_frame_index
    idx = CArray.time_series("2020-01-01", count: 5, unit: :D)
    df  = CAFrame.new({ "v" => col([0, 0, 0, 0, 8.0], 1, 2, 3) },
                      axis_name: "time", index: idx)
    df.fill("v", :linear)
    assert_equal([0.0, 2.0, 4.0, 6.0, 8.0], df["v"].to_a)
  end

  def test_linear_falls_back_to_cell_index_without_frame_index
    df = CAFrame.new("v" => col([0, 0, 8.0], 1))
    df.fill("v", :linear)
    assert_equal([0.0, 4.0, 8.0], df["v"].to_a)
  end

  # ---- time columns ------------------------------------------------------

  def time_col(masked)
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
    t[masked] = UNDEF
    t
  end

  def test_time_column_ffill_and_bfill
    # write-through works for a time column too: the fill goes through the
    # Face's storage instead of casting int64 ticks to its fixlen surface.
    df = CAFrame.new("when" => time_col(1))
    df.fill("when", :ffill)
    assert_equal(CATime, df["when"].class)
    assert_equal([19723, 19723, 19725], df["when"].parent.to_a)

    df = CAFrame.new("when" => time_col(1))
    df.fill("when", :bfill)
    assert_equal([19723, 19725, 19725], df["when"].parent.to_a)
  end

  def test_time_column_linear_without_index_uses_the_cell_position
    df = CAFrame.new("when" => time_col(1))
    df.fill("when", :linear)
    assert_equal(CATime, df["when"].class)
    assert_equal([19723, 19724, 19725], df["when"].parent.to_a)
  end

  def test_time_column_linear_uses_frame_index
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-05"],
                    unit: :D)
    t[2] = UNDEF
    df = CAFrame.new("x" => CA_FLOAT64([0, 1, 2, 3]), "when" => t).set_index("x")
    df.fill("when", :linear)
    # x = 2 sits halfway between (1, 19724) and (3, 19727) -> 19725.5 -> 19726
    assert_equal([19723, 19724, 19726, 19727], df["when"].parent.to_a)
    assert_equal(0, df["when"].count_masked)
  end

  def test_time_column_linear_leaves_the_exterior_masked
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"],
                    unit: :D)
    t[0] = UNDEF
    t[3] = UNDEF
    df = CAFrame.new("when" => t)
    df.fill("when", :linear)
    assert_equal([true, false, false, true], df["when"].is_masked.to_a)
  end

  def test_categorical_column_ffill_raises
    # fill is write-through (§3.8); categorical codes are read-only (§13.4),
    # so an in-place fill raises. Recode by rebinding a filled copy.
    keys = CArray.object(4) { |i| %w[a b c a][i] }
    keys[1] = UNDEF; keys[2] = UNDEF
    df = CAFrame.new("s" => keys.categorize)
    assert_raise(RuntimeError) { df.fill("s", :ffill) }
    df = df.append("s", df["s"].strip_mask(method: :forward))   # rebind a filled copy
    assert_equal(["a", "a", "a", "a"], df["s"].to_a)
  end

  def test_unknown_method_raises
    df = CAFrame.new("temp" => col([1.0, 0], 1))
    assert_raise(ArgumentError) { df.fill("temp", :bogus) }
  end

  def test_missing_column_raises
    df = CAFrame.new("temp" => col([1.0, 0], 1))
    assert_raise(KeyError) { df.fill("nope", :ffill) }
  end

  def test_linear_rejects_non_numeric_column
    keys = CArray.object(2) { |i| %w[a b][i] }; keys[1] = UNDEF
    df = CAFrame.new("s" => keys.categorize)
    assert_raise(ArgumentError) { df.fill("s", :linear) }
  end

  def test_chains
    df = CAFrame.new("a" => col([1.0, 0], 1), "b" => col([0, 2.0], 0))
    df.fill("a", :ffill).fill("b", :bfill)
    assert_equal([1.0, 1.0], df["a"].to_a)
    assert_equal([2.0, 2.0], df["b"].to_a)
  end
end
