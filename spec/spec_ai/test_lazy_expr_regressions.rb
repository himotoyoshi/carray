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

  # --- a scalar on the left of a one-cell array of several axes ------------

  def test_left_scalar_keeps_the_shape_of_the_array
    one = cell(:float64, 2.5)
    %i[+ - * / % **].each { |op|
      a = 2.send(op, one.lazy)
      b = 2.send(op, one)
      assert_equal b.shape, a.shape, "#{op}"
      assert_equal b.to_a, a.to_a, "#{op}"
    }
    assert_equal [1, 1], (1 < one.lazy).shape
    assert_equal [true], (1 < one.lazy).to_a.flatten
  end

  def test_left_scalar_of_one_cell_broadcasts
    one = cell(:float64, 2.5)
    assert_equal [3.5] * 9, (1 + one.lazy).broadcast_to(3, 3).to_a.flatten
    assert_equal [-1.5] * 9, (1 - one.lazy).broadcast_to(3, 3).to_a.flatten
  end

  def test_left_scalar_keeps_a_one_dimensional_shape
    one = cell(:float64, 2.5, 1)
    assert_equal [1], (1 + one.lazy).shape
    assert_equal [3.5], (1 + one.lazy).to_a
  end

  # --- object cells are asked in the order the expression was written ------

  class Word
    attr_reader :text

    def initialize (text)
      @text = text
    end

    def + (other)
      Word.new("(#{text}+#{other.is_a?(Word) ? other.text : other})")
    end

    def * (other)
      Word.new("(#{text}*#{other.is_a?(Word) ? other.text : other})")
    end

    def coerce (number)
      [Word.new(number.to_s), self]
    end
  end

  def test_left_scalar_stays_on_the_left_of_object_cells
    o = CA_OBJECT([Word.new("a"), Word.new("b")])
    assert_equal %w[(2+a) (2+b)], (2 + o.lazy).to_a.map(&:text)
    assert_equal %w[(2*a) (2*b)], (2 * o.lazy).to_a.map(&:text)
    assert_equal %w[(a+2) (b+2)], (o.lazy + 2).to_a.map(&:text)
  end

  def test_left_scalar_stays_on_the_left_as_the_eager_operator_does
    o = CA_OBJECT([Word.new("a"), Word.new("b")])
    assert_equal (2 + o).to_a.map(&:text), (2 + o.lazy).to_a.map(&:text)
  end
end
