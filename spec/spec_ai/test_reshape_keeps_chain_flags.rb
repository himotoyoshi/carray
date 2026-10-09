# A reshape that folds builds its CAStride over the root, skipping the arrays
# in between.  What those arrays meant -- a value array that ignores the
# mask, a read-only view -- must still hold for the result.

require "test/unit"
require "carray"

class TestReshapeKeepsChainFlags < Test::Unit::TestCase

  def masked
    x = CArray.float64(3, 4).seq!(1)
    x[1, 1] = UNDEF
    x[0, 3] = UNDEF
    x
  end

  def test_value_array_survives_reshape_flatten_and_newaxis
    v = masked.value
    [v.reshape(4, 3), v.flatten, v[:_, nil, nil], v.insert_axis(0),
     v.flatten[0..5], v[nil, nil].reshape(12)].each do |r|
      assert_equal true,  r.value_array?
      assert_equal false, r.has_mask?
      assert_equal 0,     r.count_masked
    end
    assert_equal 78.0, v.reshape(4, 3).sum
    assert_equal [22.0, 26.0, 30.0], v.reshape(4, 3).sum(axis: 0).to_a
  end

  def test_methods_that_flatten_internally_see_the_values
    v = masked.value
    e = masked.value.copy
    assert_equal e.sort.to_a,   v.sort.to_a
    assert_equal e.cumsum.to_a, v.cumsum.to_a
    assert_equal e.median,      v.median
    assert_equal e.unique.size, v.unique.size
  end

  def test_read_only_survives_reshape
    x = CA_INT32([1, 2, 3])
    b = x[:_, nil].broadcast_to(2, 3)
    [b[:_, nil, nil], b.reshape(2, 3, 1), b[0, nil].reshape(3),
     b[0..0, nil].flatten].each do |r|
      assert_equal true, r.read_only?
      assert_raise(RuntimeError) { r[0] = 99 }
    end
    assert_equal [1, 2, 3], x.to_a
  end

  def test_plain_reshape_still_writes_and_masks
    x = masked
    r = x.reshape(4, 3)
    assert_equal false, r.read_only?
    assert_equal 2, r.count_masked
    r[0, 0] = 100
    assert_equal 100.0, x[0, 0]
  end
end
