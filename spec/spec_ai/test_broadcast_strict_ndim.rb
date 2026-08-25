require "test/unit"
require "carray"

# PROPOSAL_CARRAY_BROADCAST_STRICT_NDIM acceptance pin (AC1-AC7).
#
# 3.0 breaking: CArray.broadcast no longer trailing-aligns args of
# different ndim.  Cross-ndim is rejected with an educational error
# message suggesting :_ for explicit size-1 axis insertion.
class TestBroadcastStrictNdim < Test::Unit::TestCase

  # AC1: same ndim broadcasts unchanged
  def test_same_ndim_works
    a = CArray.int(3, 3).seq
    b = CArray.int(1, 3).seq
    aa, bb = CArray.broadcast(a, b)
    assert_equal a.dim, aa.dim
    assert_equal a.dim, bb.dim
  end

  # AC2: cross-ndim raises ArgumentError with shape info + :_ hint
  def test_cross_ndim_raises
    a = CArray.int(4, 3).seq
    b = CArray.int(3).seq
    err = assert_raise(ArgumentError) { CArray.broadcast(a, b) }
    assert_match(/ndim mismatch/, err.message)
    assert_match(/got 1 and 2/, err.message)
    assert_match(/shape=\(4, 3\)/, err.message)
    assert_match(/shape=\(3\)/, err.message)
    assert_match(/:_/, err.message)
  end

  # AC2b: error message labels indices correctly even with non-CArray interleaved
  def test_cross_ndim_error_indices_with_numeric_interleave
    a = CArray.int(4, 3).seq
    b = CArray.int(3).seq
    err = assert_raise(ArgumentError) { CArray.broadcast(a, 1.5, b) }
    assert_match(/arg\[0\]: shape=\(4, 3\)/, err.message)
    assert_match(/arg\[2\]: shape=\(3\)/, err.message)
    # 1.5 (Float) must not appear as an indexed entry
    assert_no_match(/arg\[1\]:/, err.message)
  end

  # AC3: CScalar + CArray works (CScalar is ndim-0, excluded from check)
  def test_cscalar_mix_works
    a = CArray.int(3, 3).seq
    b = CA_INT(7)  # CScalar
    aa, bb = CArray.broadcast(a, b)
    assert_equal a.dim, aa.dim
    assert_kind_of CScalar, bb
    assert_equal 7, bb[0]
  end

  # AC4: expand_scalar: true with mixed scalars + same-ndim arrays
  def test_expand_scalar_mix_works
    a = CArray.int(2, 3).seq
    b = CA_INT(5)  # CScalar
    aa, bb = CArray.broadcast(a, b, expand_scalar: true)
    assert_equal a.dim, aa.dim
    assert_equal a.dim, bb.dim
    assert_equal 5, bb[1, 2]
  end

  # AC5: block form works
  def test_block_form
    a = CArray.int(3, 3).seq
    b = CArray.int(1, 3).seq
    result = CArray.broadcast(a, b) { |aa, bb| aa + bb }
    assert_kind_of CArray, result
    assert_equal a.dim, result.dim
  end

  # AC6: all non-CArray early returns argv
  def test_all_scalar_early_return
    list = CArray.broadcast(1.0, 2.0, 3.0)
    assert_equal [1.0, 2.0, 3.0], list
  end

  # AC6b: empty argv early returns
  def test_empty_argv
    assert_equal [], CArray.broadcast
  end

  # AC7: explicit :_ alignment unblocks cross-ndim case
  def test_explicit_underscore_alignment_works
    a = CArray.int(4, 3).seq
    b = CArray.int(3).seq
    aa, bb = CArray.broadcast(a, b[:_, nil])
    assert_equal [4, 3], aa.dim
    assert_equal [4, 3], bb.dim
  end

  # Edge: single CArray arg works (no ndim comparison needed)
  def test_single_carray_arg
    a = CArray.int(2, 3).seq
    list = CArray.broadcast(a)
    assert_equal 1, list.size
    assert_equal a.dim, list[0].dim
  end

  # Edge: 1-D + 1-D same shape works
  def test_one_d_same_shape
    a = CArray.int(5).seq
    b = CArray.int(5).seq
    aa, bb = CArray.broadcast(a, b)
    assert_equal [5], aa.dim
    assert_equal [5], bb.dim
  end

  # Edge: 3 args mixing same-ndim CArrays + Float
  def test_three_args_with_float
    a = CArray.int(2, 2).seq
    b = CArray.int(1, 2).seq
    aa, bb, cc = CArray.broadcast(a, b, 3.14)
    assert_equal [2, 2], aa.dim
    assert_equal [2, 2], bb.dim
    assert_equal 3.14, cc
  end

end
