require "test/unit"
require "carray"
require "stringio"

# A CSV cell is data, not a Ruby literal. CAFrame#cast (and so
# from_csv(types:)) reads an object column into a number type with a decimal
# grammar: "010" is ten, "0x1F" / "1_000" are not numbers, and a value the
# target type cannot hold is UNDEF.

class TestCAFrameDecimalCast < Test::Unit::TestCase
  def read(text, types)
    CAFrame.from_csv(StringIO.new(text), types: types)
  end

  def test_leading_zero_is_decimal
    df = read("code\n010\n007\n08\n", "code" => :int32)
    assert_equal [10, 7, 8], df["code"].to_a
  end

  def test_ruby_literal_forms_are_not_numbers
    df = read("i,f\n0x1F,0x1F\n1_000,1_000\n0b11,0o7\n", "i" => :int64, "f" => :float64)
    assert_equal [UNDEF] * 3, df["i"].to_a
    assert_equal [UNDEF] * 3, df["f"].to_a
  end

  def test_integer_target_refuses_fractions_and_exponents
    df = read("a\n1.5\n1e3\n1.0\n 7 \n", "a" => :int32)
    assert_equal [UNDEF, UNDEF, UNDEF, 7], df["a"].to_a
  end

  def test_float_forms
    df = read("a\n1.\n.5\n-.5e-2\n1E3\nnan\n-Inf\n1e\ne3\n+\n", "a" => :float64)
    got = df["a"].to_a
    assert_equal [1.0, 0.5, -0.005, 1000.0], got[0, 4]
    assert got[4].nan?
    assert_equal(-Float::INFINITY, got[5])
    assert_equal [UNDEF] * 3, got[6, 3]
  end

  def test_value_outside_the_type_is_undef
    df = read("a,b\n127,255\n128,256\n-128,-1\n-129,0\n", "a" => :int8, "b" => :uint8)
    assert_equal [127, UNDEF, -128, UNDEF], df["a"].to_a
    assert_equal [255, UNDEF, UNDEF, 0], df["b"].to_a
  end

  def test_int64_limits
    df = read("a\n9223372036854775807\n-9223372036854775808\n9223372036854775808\n",
              "a" => :int64)
    assert_equal [2**63 - 1, -2**63, UNDEF], df["a"].to_a
  end

  def test_float_is_correctly_rounded
    df = read("a\n0.1\n9007199254740993\n", "a" => :float64)
    assert_equal [0.1, 9007199254740993.0], df["a"].to_a
  end

  def test_empty_cell_stays_undef_and_type_is_kept
    df = read("a\n1\n\n3\n", "a" => :int32)
    assert_equal :int32, df["a"].data_type
    assert_equal [1, UNDEF, 3], df["a"].to_a
  end

  # An object column holding Ruby numbers: an Integer that fits, or a Float
  # with no fractional part, is kept; anything else is UNDEF.
  def test_non_string_cells
    df = CAFrame.new("a" => CA_OBJECT([1, 2.0, 2.5, 300, nil, "3"]))
    df.cast("a" => :int8)
    assert_equal [1, 2, UNDEF, UNDEF, UNDEF, 3], df["a"].to_a
  end

  # A column that is a view (from_csv hands out views over one backing array).
  def test_view_column
    base = CA_OBJECT([["1", "010"], ["2", "0x1F"]])
    df = CAFrame.new("a" => base[nil, 1])
    df.cast("a" => :int32)
    assert_equal [10, UNDEF], df["a"].to_a
  end

  def test_other_targets_still_use_to_type
    df = read("a\nx\n", "a" => :object)
    assert_equal ["x"], df["a"].to_a
  end
end
