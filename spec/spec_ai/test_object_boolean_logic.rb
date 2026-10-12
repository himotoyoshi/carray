require "test/unit"
require "carray"

# A logical operator between a boolean array and an object array reads the
# boolean cells as true / false, in either order, as Ruby does on the
# elements.

class TestObjectBooleanLogic < Test::Unit::TestCase

  def test_logical_operators_match_ruby
    ov = [true, true, false, false]
    bv = [true, false, true, false]
    o = CA_OBJECT(ov)
    b = CA_BOOLEAN(bv)
    { :& => :&, :| => :|, :^ => :^ }.each do |op, rop|
      exp = ov.zip(bv).map { |x, y| x.send(rop, y) }
      assert_equal exp, o.send(op, b).to_a, "object #{op} boolean"
      assert_equal bv.zip(ov).map { |x, y| x.send(rop, y) }, b.send(op, o).to_a, "boolean #{op} object"
    end
    assert_equal ov.zip(bv).map { |x, y| x && y }, o.and(b).to_a
    assert_equal ov.zip(bv).map { |x, y| x || y }, o.or(b).to_a
  end

  def test_masked_boolean_cell_stays_masked
    m = CA_BOOLEAN([true, false])
    m[0] = UNDEF
    assert_equal [UNDEF, false], (CA_OBJECT([true, true]) & m).to_a
  end

  def test_arithmetic_still_reads_a_boolean_as_zero_or_one
    assert_equal [2, 1], (CA_OBJECT([1, 1]) + CA_BOOLEAN([true, false])).to_a
  end

end
