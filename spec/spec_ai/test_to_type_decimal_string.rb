require "test/unit"
require "carray"

# to_type reads a String cell of an object array as a decimal number, the
# same grammar CAFrame#cast and a store use. A cell that does not read, or an
# integer the type cannot hold, is UNDEF.
class TestToTypeDecimalString < Test::Unit::TestCase
  CELLS = ["010", "08", "0x10", "1_000", "1.0", "1e3", "1.5", " 7 ", "300", "", "x"]

  def test_integer
    assert_equal [10, 8, UNDEF, UNDEF, 1, 1000, UNDEF, 7, 300, UNDEF, UNDEF],
                 CA_OBJECT(CELLS).to_type(:int32).to_a
  end

  def test_integer_out_of_range_is_undef
    assert_equal [10, 8, UNDEF, UNDEF, 1, UNDEF, UNDEF, 7, UNDEF, UNDEF, UNDEF],
                 CA_OBJECT(CELLS).to_type(:int8).to_a
    assert_equal [UNDEF, 0], CA_OBJECT(["-1", "-0"]).to_type(:uint8).to_a
  end

  def test_float
    assert_equal [10.0, 8.0, UNDEF, UNDEF, 1.0, 1000.0, 1.5, 7.0, 300.0, UNDEF, UNDEF],
                 CA_OBJECT(CELLS).to_type(:float64).to_a
  end

  # Before, "010" was 8 as an integer and 10.0 as a float.
  def test_integer_and_float_agree
    a = CA_OBJECT(["010", "07", "08"])
    assert_equal a.to_type(:float64).to_a, a.to_type(:int64).to_a.map(&:to_f)
  end

  def test_complex_reads_a_real_as_decimal
    assert_equal [UNDEF, Complex(1, 2), Complex(10, 0)],
                 CA_OBJECT(["0x10", "1+2i", "010"]).to_type(:cmplx128).to_a
  end

  # A number that is not a String keeps its conversion.
  def test_non_string_cells_are_unchanged
    assert_equal [44, 2, UNDEF], CA_OBJECT([300, 2.7, nil]).to_type(:int8).to_a
  end
end
