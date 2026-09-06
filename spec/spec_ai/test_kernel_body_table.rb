require "test/unit"
require "carray"

# The kernel bodies are generated into the extension as text, so that a
# caller which has to compute the same thing somewhere else -- a compiler
# handed an expression tree -- can emit what the eager kernel computes
# rather than restating it.  Reading the generator at runtime would put a
# build-time tool in the running process, so the table is built when the
# kernels themselves are.
class TestKernelBodyTable < Test::Unit::TestCase

  def test_returns_the_body_for_an_operation_at_a_data_type
    assert_equal "(#3) = (#1) + (#2);",
                 CArray.__kernel_body__(:binop, :add, :float64)
    assert_equal "(#3) = (#1) * (#2);",
                 CArray.__kernel_body__(:binop, :mul, :int32)
    assert_equal "(#4) = fma((#1), (#2), (#3));",
                 CArray.__kernel_body__(:triop, :fma, :float64)
  end

  def test_takes_the_data_type_an_array_reports
    a = CArray.float64(3)
    assert_equal CArray.__kernel_body__(:binop, :sub, :float64),
                 CArray.__kernel_body__(:binop, :sub, a.data_type)
  end

  def test_takes_symbols_or_strings
    assert_equal CArray.__kernel_body__(:binop, :add, :float64),
                 CArray.__kernel_body__("binop", "add", "float64")
  end

  def test_a_body_that_differs_by_data_type_differs_here
    int   = CArray.__kernel_body__(:binop, :pmax, :int32)
    float = CArray.__kernel_body__(:binop, :pmax, :float64)
    assert_not_equal int, float
    assert_match(/fmax/, float)
  end

  def test_multi_line_bodies_keep_their_lines
    body = CArray.__kernel_body__(:binop, :mod, :int32)
    assert_include body, "ca_zerodiv"
    assert_operator body.lines.size, :>, 1
  end

  def test_the_object_lane_is_absent
    # Those bodies call back into the interpreter, so they cannot be
    # compiled apart from it.
    assert_nil CArray.__kernel_body__(:binop, :add, :object)
    assert_nil CArray.__kernel_body__(:monop, :frac, :object)
  end

  def test_an_operation_it_does_not_have_is_nil
    assert_nil CArray.__kernel_body__(:binop, :no_such_operation, :float64)
    assert_nil CArray.__kernel_body__(:no_such_kind, :add, :float64)
    assert_nil CArray.__kernel_body__(:binop, :add, :no_such_type)
  end

  def test_placeholders_are_left_for_the_caller
    # `#1` and `#2` are the operands, `#3` the output; the caller puts its
    # own expressions in their place.
    body = CArray.__kernel_body__(:binop, :add, :float64)
    assert_include body, "#1"
    assert_include body, "#2"
    assert_include body, "#3"
  end

  def test_every_numeric_data_type_is_covered_for_a_plain_operation
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
       float32 float64].each do |dt|
      assert_not_nil CArray.__kernel_body__(:binop, :add, dt), "add/#{dt}"
      assert_not_nil CArray.__kernel_body__(:monop, :neg, dt), "neg/#{dt}"
    end
  end
end
