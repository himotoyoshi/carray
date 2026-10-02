# A lazy expression evaluates its values each time it is read, so its mask
# must follow its operands the same way: a cell masked in an operand after
# the expression was first read is masked in the expression, and a cell
# unmasked there is unmasked here.  Reading the mask must not give an
# operand a mask it did not have, and the mask of a read-only expression
# is read-only.
#
# Pinned here:
#   1. binop, comparison, triop and the Kleene `&` / `|` agree with the
#      eager result after their operands' masks change, whichever operands
#      were masked when the expression was first read,
#   2. a masked cell never reads back as a value,
#   3. reading the mask leaves an unmasked operand without one,
#   4. writing to the mask of a read-only expression raises and changes
#      nothing,
#   5. invert_mask refuses a frozen array, a view of one, and a lazy
#      expression, without changing the mask first.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyMaskLive < Test::Unit::TestCase

  def operands (mask_a, mask_b)
    a = CArray.float64(4, 6).seq
    b = CArray.float64(4, 6).seq(100)
    a[1, 2] = UNDEF if mask_a
    b[3, 0] = UNDEF if mask_b
    [a, b]
  end

  def bools (mask_a, mask_b)
    a = CArray.boolean(4, 6) { |i| i.even? }
    b = CArray.boolean(4, 6) { |i| (i % 3).zero? }
    a[0, 0] = UNDEF if mask_a
    b[0, 1] = UNDEF if mask_b
    [a, b]
  end

  def assert_same_answer (lazy, eager, msg)
    assert_equal eager.to_a, lazy.to_a, "#{msg}: values"
    assert_equal eager.is_masked.to_a, lazy.is_masked.to_a, "#{msg}: is_masked"
    assert_equal eager.count_masked, lazy.count_masked, "#{msg}: count_masked"
  end

  NUMERIC = {
    "binop"  => [->(a, b) { a.lazy + b },        ->(a, b) { a + b }],
    "bincmp" => [->(a, b) { a.lazy.gt(b) },      ->(a, b) { a.gt(b) }],
    "scalar" => [->(a, b) { a.lazy.gt(3) },      ->(a, b) { a.gt(3) }],
    "moncmp" => [->(a, b) { a.lazy.is_nan },     ->(a, b) { a.is_nan }],
    "monop"  => [->(a, b) { a.lazy.sqrt },       ->(a, b) { a.sqrt }],
    "triop"  => [->(a, b) { a.lazy.fma(b, b) },  ->(a, b) { a.fma(b, b) }],
    "chain"  => [->(a, b) { (a.lazy + b) * 2 },  ->(a, b) { (a + b) * 2 }],
  }

  MUTATIONS = {
    "mask a"   => ->(a, b) { a[2, 1] = UNDEF },
    "mask b"   => ->(a, b) { b[0, 5] = UNDEF },
    "unmask a" => ->(a, b) { a.unmask },
    "both"     => ->(a, b) { a[2, 1] = UNDEF; b[0, 5] = UNDEF; a[1, 2] = 7.0 },
  }

  [[true, false], [false, true], [true, true]].each do |ma, mb|
    NUMERIC.each do |name, (lazy, eager)|
      MUTATIONS.each do |mname, mut|
        define_method("test_#{name}_#{ma}_#{mb}_#{mname.tr(' ', '_')}") do
          a, b = operands(ma, mb)
          v = lazy.(a, b)
          v.to_a
          mut.(a, b)
          assert_same_answer v, eager.(a, b), "#{name} a=#{ma} b=#{mb} #{mname}"
        end
      end
    end
  end

  KLEENE = {
    "or"  => [->(a, b) { a.lazy | b }, ->(a, b) { a | b }],
    "and" => [->(a, b) { a.lazy & b }, ->(a, b) { a & b }],
  }

  [[true, false], [false, true], [true, true]].each do |ma, mb|
    KLEENE.each do |name, (lazy, eager)|
      define_method("test_kleene_#{name}_#{ma}_#{mb}") do
        a, b = bools(ma, mb)
        v = lazy.(a, b)
        v.to_a
        a[2, 2] = UNDEF
        b[3, 3] = UNDEF
        b[0, 1] = true
        assert_same_answer v, eager.(a, b), "kleene #{name} a=#{ma} b=#{mb}"
      end
    end
  end

  def test_masked_cell_does_not_read_as_value
    a, b = operands(true, true)
    v = a.lazy + b
    v.to_a
    a[2, 1] = UNDEF
    assert_equal UNDEF, v[2, 1]
    assert_equal (a + b).sum, v.sum
  end

  def test_reading_mask_leaves_unmasked_operand_alone
    a, b = operands(true, false)
    v = a.lazy + b
    v.mask
    v.to_a
    assert_equal false, b.has_mask?
    b[0, 5] = UNDEF
    assert_equal true, v.is_masked[0, 5]
  end

  def test_mask_of_readonly_expression_is_readonly
    { "monop"  => ->(a, b) { a.lazy.sqrt },
      "binop"  => ->(a, b) { a.lazy + b },
      "bincmp" => ->(a, b) { a.lazy.gt(3) },
      "moncmp" => ->(a, b) { a.lazy.is_nan } }.each do |name, make|
      a, b = operands(true, true)
      v = make.(a, b)
      m = v.mask
      assert_raise_kind_of(RuntimeError, name) { m[0, 0] = 1 }
      assert_equal 1, a.count_masked, name
      assert_equal false, v.is_masked[0, 0], name
    end
  end

  def test_invert_mask_refuses_frozen_and_lazy
    { "frozen"      => ->(a) { a.freeze; a },
      "frozen view" => ->(a) { a.freeze; a[0..3, 0..5] },
      "lazy"        => ->(a) { a.lazy.sqrt } }.each do |name, make|
      a, = operands(true, false)
      v = make.(a)
      assert_raise_kind_of(RuntimeError, name) { v.invert_mask }
      assert_equal 1, a.count_masked, name
      assert_equal true, a.is_masked[1, 2], name
    end
  end

end
