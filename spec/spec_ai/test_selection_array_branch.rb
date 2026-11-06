require "test/unit"
require "carray"

# A Ruby Array has no data type of its own.  As a branch of then_else, a
# choice of CArray.select or a result of a conditional callable it is
# refused beside numeric or boolean values; it stays one value of an
# object result.
class TestSelectionArrayBranch < Test::Unit::TestCase

  def setup
    @b = CA_BOOLEAN([true, false, true])
    @i = CA_INT32([1, 2, 3])
  end

  def assert_refused (name, &block)
    e = assert_raise(TypeError, &block)
    assert_match(/\A#{name}: a Ruby Array can not be a value to select/, e.message)
    e
  end

  def test_then_else_refuses_an_array_branch
    e = assert_refused("then_else") { @b.then_else(@i, [9, 9, 9]) }
    assert_match(/beside int32 values/, e.message)
    assert_match(/CA_INT64\(ary\) or CA_FLOAT64\(ary\)/, e.message)
    assert_refused("then_else") { @b.then_else([9, 9, 9], @i) }
    assert_refused("then_else") { @b.then_else(@i.lazy, [9, 9, 9]) }
    assert_refused("then_else") { @b.then_else(1, [9, 9, 9]) }
    assert_refused("then_else") { @b.then_else([1, 1, 1], [9, 9, 9]) }
    assert_refused("then_else") { @b.then_else([9, 9, 9], UNDEF) }
    e = assert_refused("then_else") { @b.then_else(@b, [true, true, true]) }
    assert_match(/CA_BOOLEAN\(ary\)/, e.message)
  end

  def test_a_carray_branch_is_taken
    assert_equal [1, 9, 3], @b.then_else(@i, CA_INT32([9, 9, 9])).to_a
    assert_equal "float64", @b.then_else(@i, CA_FLOAT64([9.5] * 3)).data_type_name
  end

  def test_an_object_result_keeps_an_array_as_one_value
    r = @b.then_else(CA_OBJECT([1, 2, 3]), [9])
    assert_equal [1, [9], 3], r.to_a
    assert_equal ["x", [9], "x"], @b.then_else("x", [9]).to_a
  end

  def test_select_and_conditional_refuse
    assert_refused("select") { CArray.select([@b], [[9, 9, 9]], default: 0) }
    assert_equal [1, 0, 3], CArray.select([@b], [@i], default: 0).to_a
    assert_refused("conditional") { @i.conditional(@b, ->(v) { [0] }, ->(v) { v }) }
  end

end
