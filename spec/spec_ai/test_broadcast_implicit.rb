require "test/unit"
require "carray"

# Phase U.2.1: implicit size-1 broadcasting in binary ops (case A).
#
# Rules:
#   - ndim must match between operands (no NumPy-style dim-prepending)
#   - axes pairwise: equal => keep, one side is 1 => broadcast,
#     otherwise => RuntimeError (data size mismatch)
#   - CScalar operand: passes through unchanged (existing path)
#   - mask, data_type, ordering with reduce / sort etc. unaffected

class TestBroadcastImplicit < Test::Unit::TestCase

  def test_col_plus_full
    a = CArray.int32(3, 1).seq           # (3, 1) -> [[0],[1],[2]]
    b = CArray.int32(3, 4).seq           # (3, 4) -> 0..11
    c = a + b
    assert_equal [3, 4], c.dim
    # Row i adds i to every column of b's row i
    4.times do |j|
      3.times do |i|
        assert_equal i + b[i, j], c[i, j]
      end
    end
  end

  def test_row_plus_full
    a = CArray.int32(1, 4).seq           # (1, 4) -> [[0,1,2,3]]
    b = CArray.int32(3, 4).seq           # (3, 4)
    c = a + b
    assert_equal [3, 4], c.dim
    3.times do |i|
      4.times do |j|
        assert_equal j + b[i, j], c[i, j]
      end
    end
  end

  def test_outer_sum_via_col_row
    a = CArray.int32(3, 1).seq           # column [[0],[1],[2]]
    b = CArray.int32(1, 4).seq           # row    [[0,1,2,3]]
    c = a + b                             # outer sum (3, 4)
    assert_equal [3, 4], c.dim
    3.times do |i|
      4.times do |j|
        assert_equal i + j, c[i, j]
      end
    end
  end

  def test_axis0_mismatch_still_raises
    a = CArray.int32(3, 4).seq
    b = CArray.int32(2, 4).seq
    assert_raise(RuntimeError) { a + b }
  end

  def test_ndim_mismatch_still_raises
    a = CArray.int32(3).seq               # (3,)
    b = CArray.int32(3, 4).seq            # (3, 4)
    assert_raise(RuntimeError) { a + b }
    # explicit :* still works (a's axis 0 maps to b's axis 0, add
    # broadcast axis for b's axis 1):
    assert_equal [3, 4], (a[nil, :*] + b).dim
  end

  def test_scalar_passthrough_unchanged
    a = CArray.int32(3, 4).seq
    s = CA_INT32(10)
    c = a + s
    assert_equal [3, 4], c.dim
    12.times { |k| assert_equal a[k / 4, k % 4] + 10, c[k / 4, k % 4] }
  end

  def test_same_shape_is_noop
    a = CArray.int32(3, 4).seq
    b = CArray.int32(3, 4).seq + 1
    c = a + b
    assert_equal [3, 4], c.dim
    assert_equal a.to_ca + b.to_ca, c
  end

  def test_both_size_one_axes
    a = CArray.int32(1, 1).seq + 5        # [[5]]
    b = CArray.int32(3, 4).seq
    c = a + b
    assert_equal [3, 4], c.dim
    3.times do |i|
      4.times do |j|
        assert_equal 5 + b[i, j], c[i, j]
      end
    end
  end

  def test_chained_arith
    a = CArray.float64(3, 1).seq
    b = CArray.float64(1, 4).seq + 1.0
    c = (a + b) * b
    assert_equal [3, 4], c.dim
    3.times do |i|
      4.times do |j|
        assert_in_delta (i.to_f + (j + 1)) * (j + 1), c[i, j], 1e-12
      end
    end
  end

  def test_mul_and_sub
    a = CArray.int32(3, 1).seq + 1        # [[1],[2],[3]]
    b = CArray.int32(1, 4).seq + 1        # [[1,2,3,4]]
    times = a * b
    diff  = a - b
    3.times do |i|
      4.times do |j|
        assert_equal (i + 1) * (j + 1), times[i, j]
        assert_equal (i + 1) - (j + 1), diff[i, j]
      end
    end
  end

  def test_broadcast_view_is_readonly
    a = CArray.int32(3, 1).seq
    b = CArray.int32(3, 4).seq
    # The broadcast view created internally is read-only; user-visible
    # result of (a + b) is a fresh CArray and stays writable.
    c = a + b
    assert_nothing_raised { c[0, 0] = 99 }
    # Source operands unchanged
    assert_equal [[0], [1], [2]], a.to_a
  end

end
