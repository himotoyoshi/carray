require "test/unit"
require "carray"

# A string stored into a numeric array is read as Ruby reads it: Float()
# for float, Complex() (after Float()) for complex, Integer() for integer.
# A string that is not a number raises in every data type; float and
# complex used to read it as 0.  Filling masked cells with UNDEF leaves
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
      assert_equal 16.0,   store(t, "0x10")
      assert store(t, "nan").nan?
      assert_equal(-Float::INFINITY, store(t, "-inf"))
      ["x", "", "1+2i"].each do |s|
        assert_raise(ArgumentError, "#{t} #{s.inspect}") { store(t, s) }
      end
    end
  end

  def test_complex_reads_a_real_as_float_and_the_rest_as_complex
    assert_equal Complex(2.5, 0), store(:cmplx128, "2.5")
    assert_equal Complex(16, 0),  store(:cmplx128, "0x10")
    assert_equal Complex(1, 2),   store(:cmplx128, "1+2i")
    assert store(:cmplx128, "nan").real.nan?
    ["x", ""].each do |s|
      assert_raise(ArgumentError, s.inspect) { store(:cmplx128, s) }
    end
  end

  def test_integer_is_unchanged
    assert_equal 3,  store(:int32, " 3 ")
    assert_equal 16, store(:int32, "0x10")
    ["x", "", "2.5"].each do |s|
      assert_raise(ArgumentError, s.inspect) { store(:int32, s) }
    end
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
