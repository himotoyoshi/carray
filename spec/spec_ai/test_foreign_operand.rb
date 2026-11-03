require "test/unit"
require "carray"

# A value a numeric or boolean array can not hold (nil, a String, a Symbol,
# another object) answers as Ruby's numbers answer it: an operator refuses
# it (TypeError), an ordering refuses it (ArgumentError), and a value query
# finds no cell. true and false are the numbers 0 and 1.
class TestForeignOperand < Test::Unit::TestCase
  OBJ = Object.new
  FOREIGN = ["3", :s, nil, OBJ]

  def arrays
    { int64: CA_INT64([1, 2]), uint8: CA_UINT8([1, 2]), float64: CA_FLOAT64([1.0, 2.0]),
      float32: CA_FLOAT32([1.0, 2.0]), cmplx128: CA_CMPLX128([1, 2]),
      boolean: CA_BOOLEAN([true, false]) }
  end

  def test_an_operator_refuses_a_foreign_value
    arrays.each do |t, a|
      FOREIGN.each do |v|
        [-> { a + v }, -> { a * v }, -> { a.copy.add!(v) }, -> { (a.lazy + v).copy },
         -> { CArray.fuse { a - v }.copy }].each do |op|
          assert_raise(TypeError, "#{t} #{v.inspect}") { op.call }
        end
      end
    end
  end

  def test_the_operator_message_names_both_sides
    e = assert_raise(TypeError) { CA_FLOAT64([1.0]) + "3" }
    assert_equal "+: String can't be coerced into Float", e.message
    e = assert_raise(TypeError) { CA_INT64([1]) + nil }
    assert_equal "+: nil can't be coerced into Integer", e.message
    e = assert_raise(TypeError) { CA_CMPLX128([1]) * :s }
    assert_equal "*: :s can't be coerced into Complex", e.message
  end

  def test_eq_and_ne_find_no_match
    arrays.each do |t, a|
      FOREIGN.each do |v|
        assert_equal [false, false], a.eq(v).to_a, "#{t} #{v.inspect}"
        assert_equal [true, true], a.ne(v).to_a, "#{t} #{v.inspect}"
        assert_equal [false, false], a.lazy.eq(v).copy.to_a, "lazy #{t} #{v.inspect}"
      end
    end
  end

  def test_no_match_keeps_the_mask
    a = CA_FLOAT64([1.0, 2.0])
    a[1] = UNDEF
    assert_equal [false, UNDEF], a.eq("3").to_a
  end

  def test_count_and_search_find_nothing
    [CA_INT64([1, 2]), CA_FLOAT64([1.0, 2.0])].each do |a|
      FOREIGN.each do |v|
        assert_equal 0, a.count(v)
        assert_nil a.search(v)
      end
    end
  end

  def test_an_ordering_refuses_a_foreign_value
    arrays.each do |t, a|
      next if t == :cmplx128
      FOREIGN.each do |v|
        [-> { a < v }, -> { a >= v }, -> { a.pmax(v) }, -> { a.minimum(v) },
         -> { (a.lazy < v).copy }, -> { a.lazy.pmin(v).copy }].each do |op|
          assert_raise(ArgumentError, "#{t} #{v.inspect}") { op.call }
        end
      end
    end
    e = assert_raise(ArgumentError) { CA_FLOAT64([1.0]) < "3" }
    assert_equal "<: comparison of Float with String failed", e.message
  end

  def test_complex_keeps_its_own_refusal_of_ordering
    assert_raise(TypeError) { CA_CMPLX128([1]) < "3" }
    assert_raise(TypeError) { CA_CMPLX128([1]) < 3 }
  end

  def test_true_and_false_are_zero_and_one
    f = CA_FLOAT64([1.0, 2.0])
    assert_equal [2.0, 3.0], (f + true).to_a
    assert_equal [1.0, 2.0], (f + false).to_a
    assert_equal [true, false], f.eq(true).to_a
    assert_equal [2.0, 3.0], f.copy.add!(true).to_a
    assert_equal [2.0, 3.0], (f.lazy + true).copy.to_a
    assert_equal [Complex(2, 0), Complex(3, 0)], (CA_CMPLX128([1, 2]) + true).to_a
    assert_equal [2, 3], (CA_INT64([1, 2]) + true).to_a
  end

  def test_a_store_still_reads_text
    g = CA_FLOAT64([1.0, 2.0])
    g[0] = "3"
    assert_equal [3.0, 2.0], g.to_a
    assert_equal [3.0, 3.0], g.fill("3").to_a
  end

  def test_object_and_string_arrays_take_the_value
    assert_equal ["ab"], (CA_OBJECT(["a"]) + "b").to_a
    assert_equal [true], CA_OBJECT([nil]).eq(nil).to_a
    assert_equal [true], CA_FIXLEN(["ab"]).eq("ab").to_a
    assert_equal 1, CA_OBJECT(["x", "y"]).count("x")
  end

  def test_queries_read_true_and_false_as_one_and_zero
    [CA_INT64([1, 0, 1]), CA_FLOAT64([1.0, 0.0, 1.0])].each do |a|
      assert_equal 2, a.count(true)
      assert_equal 1, a.count(false)
      assert_equal 0, a.search(true)
      assert_equal 1, a.search(false)
      assert_equal [true, false, true], a.is_in([true]).to_a
      assert_equal [false, true, false], a.is_in(false).to_a
      assert_equal a.eq(true).to_a, a.is_in([true]).to_a
    end
    assert_equal [true, false, true], CA_CMPLX128([1, 0, 1]).is_in([true]).to_a
  end

  def test_is_in_finds_no_foreign_value
    FOREIGN.each do |v|
      assert_equal [false, false], CA_FLOAT64([1.0, 2.0]).is_in([v]).to_a
    end
  end

  def test_an_op_not_defined_for_complex_says_so_for_any_operand
    (FOREIGN + [true, 1]).each do |v|
      assert_raise(CArray::DataTypeError) { CA_CMPLX128([1]).pmax(v) }
      assert_raise(CArray::DataTypeError) { CA_CMPLX128([1]).lazy.pmax(v).copy }
    end
  end
end
