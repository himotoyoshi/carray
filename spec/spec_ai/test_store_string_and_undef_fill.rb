require "test/unit"
require "carray"

# A string stored into a numeric array is read as a decimal number, not as
# a Ruby literal: "010" is ten and "0x10" / "1_000" are not numbers. Complex
# reads a real that way and anything else through Complex(). A string that
# is not a number raises in every data type; float and complex used to read
# it as 0.  Filling masked cells with UNDEF leaves
# them undefined, as storing UNDEF does; it used to fill 0.
class TestStoreStringAndUndefFill < Test::Unit::TestCase

  def store (type, value)
    a = CArray.new(type, [1])
    a[0] = value
    a[0]
  end

  def test_float_reads_a_string_as_float_does
    [:float32, :float64].each do |t|
      assert_equal 2.5,    store(t, "2.5")
      assert_equal 3.0,    store(t, " 3 ")
      assert_equal 1000.0, store(t, "1e3")
      assert_equal 10.0,   store(t, "010")
      assert store(t, "nan").nan?
      assert_equal(-Float::INFINITY, store(t, "-inf"))
      ["x", "", "1+2i", "0x10", "1_000"].each do |s|
        assert_raise(ArgumentError, "#{t} #{s.inspect}") { store(t, s) }
      end
    end
  end

  def test_complex_reads_a_real_as_float_and_the_rest_as_complex
    assert_equal Complex(2.5, 0), store(:cmplx128, "2.5")
    assert_equal Complex(10, 0),  store(:cmplx128, "010")
    assert_equal Complex(1, 2),   store(:cmplx128, "1+2i")
    assert store(:cmplx128, "nan").real.nan?
    ["x", "", "0x10"].each do |s|
      assert_raise(ArgumentError, s.inspect) { store(:cmplx128, s) }
    end
  end

  def test_integer_reads_a_decimal_integer
    assert_equal 3,    store(:int32, " 3 ")
    assert_equal 10,   store(:int32, "010")
    assert_equal 1000, store(:int32, "1e3")
    assert_equal 1,    store(:int32, "1.0")
    ["x", "", "2.5", "0x10", "1_000", "0b11"].each do |s|
      assert_raise(ArgumentError, s.inspect) { store(:int32, s) }
    end
    assert_raise(RangeError) { store(:int8, "300") }
    assert_raise(RangeError) { store(:uint8, "-1") }
  end

  # A number that is not a String keeps its C conversion.
  def test_non_string_store_is_unchanged
    assert_equal 44, store(:int8, 300)
  end

  def test_every_store_path_agrees
    assert_raise(ArgumentError) { CArray.float64(1).fill("x") }
    assert_raise(ArgumentError) { CA_FLOAT64(["x"]) }
    assert_raise(ArgumentError) { CArray.float64(2).tap { |a| a[] = ["x", "1"] } }
    assert_equal [2.5, 1000.0], CA_FLOAT64(["2.5", "1e3"]).to_a
  end

  def test_undef_fill_leaves_the_cells_undefined
    a = CArray.float64(3).seq
    a[0] = UNDEF
    s = a.strip_mask(UNDEF)
    assert_equal [UNDEF, 1.0, 2.0], s.to_a
    assert_not_same a, s
    b = a.copy
    b.unmask(UNDEF)
    assert_equal [UNDEF, 1.0, 2.0], b.to_a
    assert_equal [7.0, 1.0, 2.0], a.strip_mask(7).to_a
  end

end
