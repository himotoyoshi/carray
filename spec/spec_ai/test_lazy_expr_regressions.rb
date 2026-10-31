require "test/unit"
require "carray"

# Defects found by building random lazy expressions and comparing them with
# the same expression computed eagerly.
class TestLazyExprRegressions < Test::Unit::TestCase

  def cell(type, value, *shape)
    a = CArray.new(type, shape.empty? ? [1, 1] : shape)
    a[0] = value
    a
  end

  def scalar(type, value)
    s = CScalar.new(type)
    s[0] = value
    s
  end

  def dirty_scratch
    masked = CArray.float64(4096)
    masked[] = UNDEF
    (masked.lazy + 1).is_masked.to_a
    (CArray.float64(4096).seq!.lazy * 2 + 7).sum
  end

  # --- the mask of a one-cell expression read over several cells -----------

  def test_mask_of_a_masked_scalar_operand_covers_every_cell
    one = cell(:float64, 1.5)
    dirty_scratch
    v = (one.lazy + scalar(:float64, UNDEF)).broadcast_to(3, 3)
    assert_equal [true] * 9, v.is_masked.to_a.flatten
    assert_equal [UNDEF] * 9, v.to_a.flatten
  end

  def test_mask_of_a_one_cell_three_operand_expression
    one = cell(:float64, 1.5)
    dirty_scratch
    v = one.lazy.fma(scalar(:float64, 2.0), scalar(:float64, UNDEF)).broadcast_to(3, 3)
    assert_equal [true] * 9, v.is_masked.to_a.flatten
  end

  def test_mask_of_a_one_cell_selection
    c = cell(:boolean, 1)
    dirty_scratch
    v = c.lazy.then_else(scalar(:float64, UNDEF), scalar(:float64, 2.0)).broadcast_to(3, 3)
    assert_equal [true] * 9, v.is_masked.to_a.flatten
  end
end
