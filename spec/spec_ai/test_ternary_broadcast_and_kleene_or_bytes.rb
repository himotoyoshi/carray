# Ternary operations (fma / fms / clip) over operands that broadcast, eager
# and lazy, and the value a Kleene OR writes into a cell it resolves.
#
# - The three operands are brought to one shape together.  Lazy used to align
#   the second and third only against the first, so `[1,4] [1,4] [3,4]` was
#   refused; eager with mixed data types cast an operand from its original
#   shape and lost its broadcast ("elements mismatch in triop").
# - A CScalar receiver takes the array's data type, as in the binary
#   operators; lazy used to promote it as an array.
# - The boolean OR writes 1 where either side is true, whatever byte sits under
#   a masked cell, so a cell Kleene resolves to true sums and counts as 1.

require 'test/unit'
require 'carray'

class TestTernaryBroadcastAndKleeneOrBytes < Test::Unit::TestCase

  def mk(t, shape)
    if shape == :scalar
      s = CScalar.new(t)
      s[0] = 2
      return s
    end
    a = CArray.new(t, shape)
    f = a.flatten
    f.elements.times { |i| f[i] = i % 3 + 1 }
    a
  end

  SHAPES = [[3, 4], [1, 4], [3, 1], [1, 1], :scalar]
  TYPES = [%i[float64 float64 float64], %i[float64 int32 float64], %i[int32 float64 int8],
           %i[float64 float64 int32], %i[int8 int8 uint8]]

  def each_case
    TYPES.each do |tx, ty, tz|
      SHAPES.product(SHAPES, SHAPES).each do |x, y, z|
        next unless [x, y, z].include?([3, 4])
        yield tx, ty, tz, x, y, z
      end
    end
  end

  def check(name, ternary, binary)
    each_case do |tx, ty, tz, x, y, z|
      label = "#{name} #{tx},#{ty},#{tz} #{x.inspect} #{y.inspect} #{z.inspect}"
      want = binary.(mk(tx, x), mk(ty, y), mk(tz, z)).copy
      e = ternary.(mk(tx, x), mk(ty, y), mk(tz, z)).copy
      l = ternary.(mk(tx, x).lazy, mk(ty, y).lazy, mk(tz, z).lazy).copy
      [e, l].each do |got|
        assert_equal want.shape, got.shape, label
        assert_equal want.data_type, got.data_type, label
        assert_equal want.to_a, got.to_a, label
      end
    end
  end

  def test_fma_broadcasts_as_the_binary_operators
    check("fma", ->(x, y, z) { x.fma(y, z) }, ->(x, y, z) { x * y + z })
  end

  def test_fms_broadcasts_as_the_binary_operators
    check("fms", ->(x, y, z) { x.fms(y, z) }, ->(x, y, z) { x * y - z })
  end

  def test_clip_with_broadcast_bounds
    x = CArray.float64(1, 4).seq!
    lo = CArray.float64(1, 1); lo[0] = 1.0
    hi = CArray.float64(3, 4); hi[] = 2.5
    want = x.pmax(lo).pmin(hi)
    assert_equal want.to_a, x.clip(lo, hi).to_a
    assert_equal want.to_a, x.lazy.clip(lo.lazy, hi.lazy).copy.to_a
    i = CArray.int32(1, 4).seq!
    assert_equal i.to_type(:float64).pmax(lo).pmin(hi).to_a, i.clip(lo, hi).to_a
  end

  def test_mixed_types_broadcast_in_eager
    a = CArray.float64(3, 4).seq!
    b = CArray.int32(1, 4).seq!
    assert_equal (a * b + a).to_a, a.fma(b, a).to_a
    c = CArray.int32(1, 1); c[0] = 2
    d = CArray.float64(3, 4).seq!
    assert_equal (c * d + d).to_a, c.fma(d, d).to_a
  end

  def test_two_operands_smaller_than_the_third_in_lazy
    x = CArray.float64(1, 4).seq!
    z = CArray.float64(3, 4).seq!
    assert_equal x.fma(x, z).to_a, x.lazy.fma(x.lazy, z.lazy).copy.to_a
    y = CArray.float64(3, 1).seq!
    assert_equal x.fma(y, z).to_a, x.lazy.fma(y.lazy, z.lazy).copy.to_a
  end

  def test_cscalar_receiver_takes_the_array_type
    s = CScalar.int32; s[0] = 2
    e = CArray.int8(3, 4).seq!
    assert_equal CA_INT8, s.fma(e, e).data_type
    assert_equal CA_INT8, s.lazy.fma(e.lazy, e.lazy).data_type
    assert_equal s.fma(e, e).to_a, s.lazy.fma(e.lazy, e.lazy).copy.to_a
    s[0] = 100
    assert_equal s.fma(e, e).to_a, s.lazy.fma(e.lazy, e.lazy).copy.to_a  # wraps in int8 both ways
  end

  def test_shapes_that_do_not_broadcast_are_still_refused
    a = CArray.float64(3, 4).seq!
    b = CA_DOUBLE([1.0])
    assert_raise(ArgumentError) { a.fma(a, b) }
    assert_raise(ArgumentError) { a.lazy.fma(a.lazy, b.lazy) }
  end

  # A masked cell whose byte is not 0 / 1 beside a true: the OR is true.
  def masked_with_bytes(bytes)
    b = CArray.boolean(bytes.size)
    b[] = false
    b.value.refer(:uint8, [bytes.size])[] = CA_UINT8(bytes)
    b[] = UNDEF
    b
  end

  def test_kleene_or_resolves_to_one
    [3, 37].each do |n|
      b = masked_with_bytes(Array.new(n) { |i| 64 + i % 3 })
      t = CArray.boolean(n); t[] = true
      [b | t, (b.lazy | t.lazy).copy].each do |r|
        assert !r.has_mask? || r.count_masked == 0
        assert_equal [1], r.value.refer(:uint8, [n]).to_a.uniq
        assert_equal n, r.sum
        assert_equal n, r.count(true)
      end
    end
  end

  def test_kleene_or_from_a_lazy_object_comparison
    a0 = CA_UINT64([4, 1, 0, 5]); a0[2] = UNDEF
    b = CA_OBJECT([[4, 1.0, 1.5, 3], [2, 2.0, -0.5, 2], [-4, -1, 2, 1.5]])
    c0 = CA_BOOLEAN([true, true, false])
    l = a0[:_, nil].lazy.ne(b.lazy) | c0[nil, :_].lazy
    e = a0[:_, nil].ne(b) | c0[nil, :_]
    assert_equal e.sum(axis: 0).to_a, l.sum(axis: 0).to_a
    assert_equal e.sum(axis: 1).to_a, l.sum(axis: 1).to_a
    assert_equal e.sum(axis: 0).to_a, l.copy.sum(axis: 0).to_a
  end

  def test_kleene_or_keeps_undetermined_cells_masked
    b = masked_with_bytes([66, 66])
    f = CA_BOOLEAN([false, false])
    [b | f, (b.lazy | f.lazy).copy].each { |r| assert_equal [UNDEF, UNDEF], r.to_a }
  end
end
