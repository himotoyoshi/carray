require "test/unit"
require "carray"

# An element-wise operation never evaluates a masked cell: a masked zero
# divisor does not raise, and a cell that does raise leaves nothing
# attached.  The eager operators and the lazy views decide which ops can
# raise on a cell from one list (ca_binop_is_trapping); this checks the two
# paths agree on every op of that list, over views so that a window left
# open would show.

class TestMaskedCellNotEvaluated < Test::Unit::TestCase

  INT_TYPES = [CA_INT8, CA_INT32, CA_INT64, CA_UINT16]

  # A raising cell in position 1: the divisor (or exponent) there is the one
  # the op cannot take.
  OPS = {
    "/"    => ->(a, b) { a / b },
    "%"    => ->(a, b) { a % b },
    "fmod" => ->(a, b) { a.fmod(b) },
    "**"   => ->(a, b) { a ** b },
  }

  def operands (type, op)
    base = CArray.new(type, [4, 2])
    left  = base[nil, 0]
    right = base[nil, 1]
    left[]  = [6, 0, 4, 3]
    signed = ![CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].include?(type)
    right[] = op == "**" ? [2, (signed ? -1 : 0), 1, 0] : [3, 0, 2, 1]
    [left, right]
  end

  def raising? (op, type)
    return true unless op == "**"
    ![CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].include?(type)
  end

  def attached
    CArray.respond_to?(:__attached_views__) ? CArray.__attached_views__ : 0
  end

  def test_a_masked_raising_cell_is_skipped_eager_and_lazy
    INT_TYPES.each do |type|
      OPS.each do |name, op|
        left, right = operands(type, name)
        masked = left.copy
        masked[1] = UNDEF
        label = "#{CArray.data_type_name(type)} #{name}"
        eager = op.(masked, right)
        lazy  = op.(masked.lazy, right).copy
        assert_equal [false, true, false, false], eager.is_masked.to_a, "#{label} eager mask"
        assert_equal eager.is_masked.to_a, lazy.is_masked.to_a, "#{label} lazy mask"
        [0, 2, 3].each { |i| assert_equal eager[i], lazy[i], "#{label} cell #{i}" }
      end
    end
  end

  def test_an_unmasked_raising_cell_raises_and_leaves_nothing_attached
    INT_TYPES.each do |type|
      OPS.each do |name, op|
        next unless raising?(name, type)
        left, right = operands(type, name)
        label = "#{CArray.data_type_name(type)} #{name}"
        before = attached
        assert_raise(ZeroDivisionError, "#{label} eager") { op.(left, right) }
        assert_equal before, attached, "#{label} eager left a view attached"
        assert_raise(ZeroDivisionError, "#{label} lazy") { op.(left.lazy, right).copy }
        assert_equal before, attached, "#{label} lazy left a view attached"
      end
    end
  end
end
