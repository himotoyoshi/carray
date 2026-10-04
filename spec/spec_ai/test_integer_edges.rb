require "test/unit"
require "carray"

# Integer arithmetic at the edge of the integer types.  Signed overflow and
# an out-of-range float-to-integer conversion have no defined result in C,
# and what they do differs between machines, so each case here pins the
# answer CArray gives whatever the machine.
class TestIntegerEdges < Test::Unit::TestCase

  # -- a shape too large to count ---------------------------------------

  # 274177 * 67280421310721 is 2**64 + 1.  Wrapped, the count would be 1
  # and every read past the first cell would leave the buffer.
  def test_a_view_whose_cell_count_overflows_is_refused
    a = CA_INT8([7])
    assert_raise(RuntimeError) { a.reshape(274177, 67280421310721) }
    assert_raise(RuntimeError) { a.refer(CA_INT8, [274177, 67280421310721]) }
    assert_raise(RuntimeError) { (a.lazy + 1).reshape(274177, 67280421310721) }
    assert_raise(RuntimeError) { CArray.int8(0).reshape(2**32, 2**32) }
    assert_raise(RuntimeError) { CA_INT8([7, 8]).tile(2**63 - 1) }
    assert_raise(RuntimeError) { CArray.float64(2**60) }
  end

  def test_an_empty_shape_is_empty_whatever_its_other_extents
    assert_equal [2**40, 2**40, 0], CArray.int8(0).reshape(2**40, 2**40, 0).shape
  end

  # -- a block index whose last cell is past any index ------------------

  def test_a_block_whose_bound_overflows_is_out_of_range
    a = CA_INT64([1, 2, 3])
    assert_raise(IndexError) { a[[0, 3, 2**63 - 1]] }
    assert_raise(IndexError) { a[[2, 2**63 - 1]] }
    assert_raise(IndexError) { a[[1, 3, 2**63 - 1]] = 99 }
    assert_equal [1, 2, 3], a.to_a
    assert_equal [3], a[(2..0).step(-2**63)].to_a
    assert_equal [1], a[(0..2).step(2**62)].to_a
  end

  # -- a uint64 index past what an index can hold -----------------------

  def test_a_uint64_index_of_2_63_or_more_is_out_of_range
    a = CA_INT8([1, 2, 3])
    assert_raise(IndexError) { a[CA_UINT64([2**64 - 1])] }
    assert_raise(IndexError) { a[CA_UINT64([2**64 - 1])] = 9 }
    assert_equal [1, 2, 3], a.to_a
    assert_equal [3, 1], a[CA_UINT64([2, 0])].to_a
  end

  # -- a position that is not a number ----------------------------------

  def test_a_percentile_of_nan_is_refused
    v = CA_FLOAT64([1, 2, 3, 4])
    assert_raise(ArgumentError) { v.percentile(Float::NAN) }
    g = v.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    assert_raise(ArgumentError) { g.percentile(Float::NAN) }
    assert_raise(ArgumentError) { g.percentile(150) }
  end

  # Edges spanning more than a double holds, or a subnormal bin width,
  # would make the linearised bin position NaN.
  def test_histogram_edges_too_wide_or_too_narrow_bin_by_the_edges
    wide = CA_FLOAT64([9e307]).histogram1d(edges: CA_FLOAT64([-1e308, 0, 1e308]))
    assert_equal [0, 1], wide.counts.to_a
    thin = CA_FLOAT64([1.5e-320]).histogram1d(edges: CA_FLOAT64([0, 1e-320, 2e-320]))
    assert_equal [0, 1], thin.counts.to_a
  end

  # -- the signed minimum divided by -1 ---------------------------------

  # The quotient does not fit; x86 traps on it and ARM returns the
  # minimum.  CArray answers as the wrapped negation on every machine.
  def test_the_minimum_divided_by_minus_one_wraps
    x = CA_INT64([-2**63, 5, -7])
    assert_equal [-2**63, -5, 7], (x / -1).to_a
    assert_equal [0, 0, 0], (x % -1).to_a
    assert_equal [0, 0, 0], x.fmod(-1).to_a
    assert_equal [-2**63, -5, 7], (x.lazy / -1).to_a
    assert_equal [-2**31], CA_INT32([-1]).rcp_mul(CA_INT32([-2**31])).to_a
    assert_equal [-128], (CA_INT8([-128]) / -1).to_a
  end

  # rcp_mul and rcp divide as `/` does, rounding toward minus infinity.
  def test_rcp_and_rcp_mul_floor_like_div
    a = CA_INT32([2, 2, -2])
    b = CA_INT32([-7, 7, 7])
    assert_equal (b / a).to_a, a.rcp_mul(b).to_a
    c = CA_INT32([-2, -1, 1, 2, 5])
    assert_equal (1 / c).to_a, c.rcp.to_a
    assert_equal [1, 0, 0], CA_UINT8([1, 2, 3]).rcp.to_a
  end

  # -- an Integer operand the array's type cannot hold ------------------

  def test_an_integer_operand_that_does_not_fit_is_refused
    assert_raise(RangeError) { CA_INT32([5]) * 2**32 }
    assert_raise(RangeError) { CA_UINT8([0]).lazy + 256 }
    assert_raise(RangeError) { CA_UINT8([0, 0, 1]).count(256) }
    assert_raise(RangeError) { CA_INT32([0, 5, 10]).search(2**40) }
    assert_equal [2**63 + 1], (CA_UINT64([1]) + 2**63).to_a
    assert_equal [-2**63 + 1], (CA_INT64([1]) + -2**63).to_a
    assert_equal [1], (2 - CA_UINT8([1])).to_a
    assert_equal [3.5], (CA_UINT8([3]) + 0.5).to_a
  end

  # -- comparisons answer by value -------------------------------------

  OPS = { lt: :<, le: :<=, gt: :>, ge: :>=, eq: :==, ne: :!= }

  def answers (a, b, op)
    a.to_a.zip(b.to_a).map { |x, y| x.send(OPS[op], y) }
  end

  # Promotion takes uint64 beside int64 to uint64, where -7 would be
  # 2**64 - 7.  The comparison answers as the Integers would.
  def test_unsigned_and_signed_integers_compare_by_value
    pairs = [
      [CA_UINT64([7, 0, 5, 2**64 - 1]), CA_INT64([-7, 0, 9, -1])],
      [CA_UINT8([7, 200, 0]),           CA_INT8([-7, 100, -128])],
      [CA_UINT32([7, 2**32 - 1]),       CA_INT16([-7, 3])],
    ]
    pairs.each do |u, s|
      OPS.each_key do |op|
        assert_equal answers(u, s, op), u.send(op, s).to_a, "#{u.data_type_name} #{op}"
        assert_equal answers(s, u, op), s.send(op, u).to_a, "#{s.data_type_name} #{op}"
        assert_equal answers(u, s, op), u.lazy.send(op, s.lazy).to_a
        assert_equal answers(s, u, op), s.lazy.send(op, u).to_a
      end
    end
  end

  def test_a_mixed_signedness_comparison_keeps_masks_and_broadcasts
    u = CA_UINT64([7, 7])
    u[1] = UNDEF
    s = CA_INT64([-1, -1])
    assert_equal [true, UNDEF], (u > s).to_a
    assert_equal [true, UNDEF], u.lazy.gt(s).to_a
    a = CA_UINT64([[1, 2], [3, 4]])
    b = CA_INT64([[-1], [5]])
    assert_equal [[true, true], [false, false]], a.gt(b).to_a
    assert_equal [[true, true], [false, false]], a.lazy.gt(b).to_a
  end

  # An Integer outside the array's type lies beyond every cell, so the
  # answer is the same at every cell that is not masked.
  def test_an_integer_outside_the_type_compares_by_value
    u = CA_UINT8([0, 200, 7])
    u[2] = UNDEF
    assert_equal [true, true, UNDEF], (u > -1).to_a
    assert_equal [false, false, UNDEF], u.eq(256).to_a
    assert_equal [true, true, UNDEF], u.lt(256).to_a
    assert_equal [true, true, UNDEF], u.lazy.ne(-1).to_a
    assert_equal [false, false, UNDEF], (-1 > u).to_a
    assert_equal [true, true, UNDEF], (300 >= u.lazy).to_a
    assert_raise(RangeError) { -1 + u }
    assert_equal [true, true], CA_INT8([5, -3]).lt(300).to_a
    assert_equal [false], CA_UINT64([2**64 - 1]).eq(2**64).to_a
    assert_equal [true], CA_INT64([-2**63]).gt(-2**64).to_a
  end

  # -- shift counts -----------------------------------------------------

  # A count means what it means to Integer#<< and #>>: negative shifts the
  # other way, and a count past the width shifts every bit out.
  def test_shift_counts_mean_what_they_mean_to_integer
    x = CA_INT64([3, -3])
    assert_equal [0, 0], (x << 64).to_a
    assert_equal [0, -1], (x >> 64).to_a
    assert_equal [3 << -1, -3 << -1], (x << -1).to_a
    assert_equal [3 >> -1, -3 >> -1], (x >> -1).to_a
    assert_equal [4], (CA_UINT8([8]) << -1).to_a
    assert_equal [0], (CA_UINT8([8]) >> 300).to_a
    assert_equal [-2], (CA_INT8([-1]) << 1).to_a
    assert_equal [1, 0], (CA_INT32([3, -3]) << CA_INT32([-1, 40])).to_a
    assert_equal [0], (CA_INT64([3]).lazy << 64).to_a
    assert_equal [4], CA_UINT8([8]).bit_lshift(-1).to_a
  end

  # -- float to integer -------------------------------------------------

  # A NaN has no integer: to_type masks it.  A finite value outside the
  # integer type is converted as the machine's C converts it, which is
  # not pinned here because it differs between machines.
  def test_to_type_masks_nan_on_the_way_to_an_integer
    r = CA_FLOAT64([1.5, Float::NAN, -2.5]).to_type(:int32)
    assert_equal [1, UNDEF, -2], r.to_a
    f = CA_FLOAT64([1.5, Float::NAN])
    f[0] = UNDEF
    assert_equal [UNDEF, UNDEF], f.to_type(:int64).to_a
    assert_equal [true, false], f.mask.to_a, "the source's mask is left alone"
    assert_equal [1, UNDEF],
                 CA_CMPLX128([Complex(1, 0), Complex(0, Float::NAN)]).to_type(:int16).to_a
    assert_false CA_FLOAT64([1.5, 2.5]).to_type(:int32).has_mask?
  end

  # -- a Range with an excluded end ------------------------------------

  # The cells are the steps that start before the end, whether or not the
  # step divides the span.
  def test_an_excluded_end_keeps_every_step_that_starts_before_it
    assert_equal [0, 2, 4], CA_INT32(0...5, 2).to_a
    assert_equal [5, 3, 1], CA_INT32(5...0, 2).to_a
    assert_equal [0, 2], CA_INT32(0...4, 2).to_a
    assert_equal [], CA_INT32(0...0, 1).to_a
    assert_equal 4, CA_FLOAT64(0.0...1.0, 0.3).elements
  end

  # The kernels are built so that signed overflow wraps, and the flag is
  # recorded for anything (carray-jit) that compiles the same bodies.
  def test_signed_overflow_wraps_in_the_recorded_build_flags
    assert_include CArray::BUILD_FLAGS.split, "-fwrapv"
  end
end
