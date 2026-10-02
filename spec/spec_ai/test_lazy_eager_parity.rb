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

end
