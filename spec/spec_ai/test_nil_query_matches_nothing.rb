require "test/unit"
require "carray"

# nil is no value of an array that can not hold it: as a value query it
# matches no cell.  An order comparison with nil is still an error.
class TestNilQueryMatchesNothing < Test::Unit::TestCase

  ARRAYS = {
    "int32"    => proc { CA_INT32([1, 2]) },
    "uint8"    => proc { CA_UINT8([1, 2]) },
    "float32"  => proc { CA_FLOAT32([1.0, 2.0]) },
    "float64"  => proc { CA_DOUBLE([1.0, 2.0]) },
    "boolean"  => proc { CA_BOOLEAN([true, false]) },
    "fixlen"   => proc { CArray.fixlen_string(%w[ab cd], bytes: 2) },
    "string"   => proc { CArray.string(%w[a b]) },
    "time"     => proc { CArray.time(%w[2024-01-01 2024-01-02], unit: :D) },
    "timedelta" => proc {
      CArray.time(%w[2024-01-02 2024-01-03], unit: :D) -
        CArray.time(%w[2024-01-01 2024-01-01], unit: :D)
    },
  }

  ARRAYS.each do |name, build|
    define_method("test_#{name}") do
      a = build.call
      assert_equal [false, false], a.eq(nil).to_a
      assert_equal [true, true], a.ne(nil).to_a
      assert_equal 0, a.count(nil)
      assert_nil a.search(nil)
      assert_nil a.search_addr(nil)
      assert_equal [false, false], a.is_in([nil]).to_a
      assert_equal [false, false], a.is_in(CA_OBJECT([nil])).to_a
      assert_equal a.to_a, a.mask_eq(nil).to_a
    end
  end

  def test_complex_compares_and_refuses_what_it_refuses_for_any_query
    a = CA_CMPLX128([1, 2])
    assert_equal [false, false], a.eq(nil).to_a
    assert_equal [false, false], a.is_in([nil]).to_a
    assert_raise(CArray::DataTypeError) { a.count(nil) }
    assert_raise(CArray::DataTypeError) { a.search(nil) }
  end

  def test_a_face_that_can_not_be_searched_still_refuses
    a = CArray.string(%w[a b]).categorize
    assert_equal [false, false], a.eq(nil).to_a
    assert_equal 0, a.count(nil)
    assert_raise(ArgumentError) { a.search(nil) }
  end

  def test_an_object_array_holds_nil
    a = CA_OBJECT([1, nil])
    assert_equal [false, true], a.eq(nil).to_a
    assert_equal 1, a.count(nil)
    assert_equal 1, a.search(nil)
    assert_equal [false, true], a.is_in([nil]).to_a
  end

  def test_a_masked_cell_stays_masked
    a = CA_DOUBLE([1.0, 2.0, 3.0])
    a[1] = UNDEF
    assert_equal [false, UNDEF, false], a.eq(nil).to_a
    assert_equal [true, UNDEF, true], a.ne(nil).to_a
    assert_equal 0, a.count(nil)
  end

  def test_nil_among_other_values_of_a_set
    assert_equal [true, false], CA_INT32([1, 2]).is_in([1, nil]).to_a
    assert_equal [true, false], CA_DOUBLE([1.0, 2.0]).is_in([1.0, nil]).to_a
    assert_equal [true, false],
                 CArray.fixlen_string(%w[ab cd], bytes: 2).is_in(["ab", nil]).to_a
    t = CArray.time(%w[2024-01-01 2024-01-02], unit: :D)
    assert_equal [true, false], t.is_in([t[0], nil]).to_a
    assert_equal [true, false], t.is_in(CA_OBJECT([t[0], nil])).to_a
  end

  def test_axis_and_shape
    a = CArray.float64(2, 3).seq
    assert_equal [2, 3], a.eq(nil).shape
    assert_equal [0, 0, 0], a.count(nil, axis: 0).to_a
    assert_equal [UNDEF, UNDEF], a.search(nil, axis: 1).to_a
    assert_nil a.search(nil)
    assert_equal [2, 2], a[0..1, 0..1].eq(nil).shape
    assert_equal [false, false], a[CA_INT32([0, 1]), 0].eq(nil).to_a
  end

  def test_a_scalar_and_an_empty_array
    assert_equal false, CScalar.float64 { 1.0 }.eq(nil)[0]
    e = CArray.float64(0)
    assert_equal [], e.eq(nil).to_a
    assert_equal 0, e.count(nil)
    assert_nil e.search(nil)
  end

  def test_lazy_answers_the_same
    a = CA_DOUBLE([1.0, 2.0])
    assert_equal [false, false], a.lazy.eq(nil).to_a
    assert_equal [true, true], (a.lazy + 1).ne(nil).to_a
    o = CA_OBJECT([1, nil])
    assert_equal [false, true], o.lazy.eq(nil).to_a
  end

  def test_an_order_comparison_is_still_an_error
    assert_raise(ArgumentError) { CA_INT32([1]) < nil }
    assert_raise(ArgumentError) { CA_DOUBLE([1.0]) < nil }
    assert_raise(TypeError)     { CA_INT32([1]).bsearch(nil) }
  end

end
