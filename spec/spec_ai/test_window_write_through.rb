# A window that covers whole inner axes points into its parent's storage.
# A write through it reaches the parent however the write opens the
# window: attach (fill, bang methods) or allocate (seq!, a store that
# converts).

require 'test/unit'
require 'carray'

class TestWindowWriteThrough < Test::Unit::TestCase

  def setup
    @b = CArray.float64(3, 4).seq!(1)
    @w = @b.window(1..2, 0..3)
  end

  def test_seq_bang
    @w.seq!(100)
    assert_equal(CArray.float64(2, 4).seq!(100).to_a, @b[1..2, nil].to_a)
  end

  def test_store_that_converts
    @w[] = CArray.int32(2, 4).seq!(100)
    assert_equal(CArray.float64(2, 4).seq!(100).to_a, @b[1..2, nil].to_a)
  end

  def test_store_that_converts_with_a_mask
    m = CArray.int32(2, 4).seq!(100)
    m[0, 0] = UNDEF
    @w[] = m
    assert_equal([[UNDEF, 101.0, 102.0, 103.0], [104.0, 105.0, 106.0, 107.0]],
                 @b[1..2, nil].to_a)
  end

  def test_window_of_a_transpose
    b = CArray.float64(2, 3, 4).seq!(1)
    b.transpose.window(0..3, 0..2, 0..1).seq!(100)
    assert_equal(CArray.float64(4, 3, 2).seq!(100).to_a, b.transpose.to_a)
  end

end
