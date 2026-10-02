# A lazy expression gives the answer the eager expression gives: the same
# values, data_type and mask, and it raises where the eager one raises.

require 'test/unit'
require 'carray'

class TestLazyEagerParity < Test::Unit::TestCase

  def assert_parity (eager, lazy)
    assert_equal(eager.data_type, lazy.data_type, "data_type")
    assert_equal(eager.to_a, lazy.to_a, "values")
    assert_equal(eager.is_masked.to_a, lazy.is_masked.to_a, "mask")
  end

  # ---- fixlen comparison ----

  def fixlen (words)
    CArray.fixlen(words.size, bytes: words.first.bytesize) { |i| words[i] }
  end

  def test_fixlen_compare_each_op
    x = fixlen(%w[aaaaaaaa bbbbbbbb cccccccc])
    y = fixlen(%w[aaaaaaaa bxbbbbbb bccccccc])
    %i[eq ne lt gt le ge].each do |op|
      assert_parity(x.send(op, y), x.lazy.send(op, y.lazy))
    end
  end

  def test_fixlen_compare_with_itself
    x = fixlen(%w[aaaaaaaa bbbbbbbb cccccccc])
    assert_equal([true, true, true], x.lazy.eq(x.lazy).to_a)
  end

  def test_fixlen_compare_different_widths
    x = fixlen(%w[aaaaaaaa bbbbbbbb cccccccc])
    s = fixlen(%w[aaaa aaaa aaaa])
    assert_parity(x.eq(s), x.lazy.eq(s.lazy))
  end

  def test_fixlen_compare_repeated_does_not_corrupt_heap
    x = fixlen(%w[aaaaaaaa bbbbbbbb cccccccc])
    200.times { x.lazy.eq(x.lazy).to_a }
    GC.start
    assert_equal([true, true, true], x.lazy.eq(x.lazy).to_a)
  end

  # ---- comparison read over part of a box ----

  def test_compare_column_of_entity_operands
    a = CA_INT32([[1,5,3,7,0,2],[4,4,4,4,4,4],[9,1,8,2,7,3],[0,6,0,6,0,6]])
    b = CA_INT32([[2,2,2,2,2,2],[1,5,3,7,0,2],[3,3,3,3,3,3],[6,0,6,0,6,0]])
    assert_equal((a < b)[nil, 2].to_a, (a.lazy < b)[nil, 2].to_a)
    assert_equal((a < b)[1..2, 1..3].to_a, (a.lazy < b.lazy)[1..2, 1..3].to_a)
  end

  def test_moncmp_inner_box_of_entity_operand
    x = CA_FLOAT64([[1,-2,3],[-4,5,-6]])
    assert_equal(x.signbit[0..1, 1..2].to_a, x.lazy.signbit[0..1, 1..2].to_a)
  end

  def test_compare_random_boxes
    srand(1)
    a = CArray.int32(3,4,5) { |i| rand(-3..3) }
    b = CArray.int32(3,4,5) { |i| rand(-3..3) }
    200.times do
      sel = a.shape.map { |d| s = rand(d); s...(s + rand(1..d-s)) }
      assert_equal((a < b)[*sel].to_a, (a.lazy < b)[*sel].to_a, sel.inspect)
      assert_equal(a.is_finite[*sel].to_a, a.lazy.is_finite[*sel].to_a, sel.inspect)
    end
  end

end
