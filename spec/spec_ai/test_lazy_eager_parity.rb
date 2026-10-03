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

  # ---- a Ruby scalar beside the array ----

  def assert_same_result (eager, lazy)
    assert_equal([eager.data_type, eager.to_a], [lazy.data_type, lazy.to_a])
  end

  def test_scalar_promotes_as_eager
    a = CA_INT32([1, 2, 3])
    f = CA_FLOAT32([1, 2, 3])
    u = CA_UINT8([1, 2, 3])
    assert_same_result(a * 0.5,              a.lazy * 0.5)
    assert_same_result(a * 0.5,              CArray.fuse { a * 0.5 })
    assert_same_result(a + Complex(1, 2),    a.lazy + Complex(1, 2))
    assert_same_result(a + true,             a.lazy + true)
    assert_same_result(f + 2.5,              f.lazy + 2.5)
    assert_same_result(u + 300,              u.lazy + 300)
    assert_same_result(CA_FLOAT64([1, 2]) + Complex(0, 1),
                       CA_FLOAT64([1, 2]).lazy + Complex(0, 1))
  end

  def test_scalar_in_comparison_promotes_as_eager
    a = CA_INT32([1, 2, 3])
    assert_same_result(a >= 2.5,   a.lazy >= 2.5)
    assert_same_result(a.eq(2.5),  a.lazy.eq(2.5))
    assert_same_result(a > true,   a.lazy > true)
    x = fixlen(%w[aaaaaaaa bbbbbbbb cccccccc])
    assert_same_result(x.eq("bbbbbbbb"), x.lazy.eq("bbbbbbbb"))
  end

  def test_scalar_in_triop_promotes_as_eager
    a = CA_INT32([1, 2, 3])
    assert_same_result(a.clip(-1.5, 1.5),  a.lazy.clip(-1.5, 1.5))
    assert_same_result(a.fma(0.5, 0.25),   a.lazy.fma(0.5, 0.25))
  end

  def test_scalar_on_the_left_promotes_as_eager_and_stays_lazy
    a = CA_INT32([1, 2, 3])
    f = CA_FLOAT32([1, 2, 3])
    assert_same_result(2.5 * a, 2.5 * a.lazy)
    assert_same_result(2.5 - a, 2.5 - a.lazy)
    assert_same_result(2 * f,   2 * f.lazy)
    assert_kind_of(CABinOp, 2.5 * a.lazy)
  end

  # ---- storing into an array the source reads from ----

  def masked_array
    c = CA_FLOAT64([1, 2, 3, 4])
    c[1] = UNDEF
    c
  end

  def test_self_store_keeps_the_source_mask
    one = CA_FLOAT64([1, 1, 1, 1])
    [
      [->(c) { c[] = c.lazy + one.lazy }, ->(c) { c[] = c + one }],
      [->(c) { c[] = c.lazy.sqrt },       ->(c) { c[] = c.sqrt }],
      [->(c) { c[] = (c.lazy > 1) },      ->(c) { c[] = (c > 1) }],
      [->(c) { c[0..2] = c[1..3].lazy + one[0..2].lazy },
       ->(c) { c[0..2] = c[1..3] + one[0..2] }],
    ].each do |lazy, eager|
      e = masked_array; eager.(e)
      l = masked_array; lazy.(l)
      assert_equal(e.to_a, l.to_a)
    end
  end

  def test_self_store_through_a_view_keeps_the_mask
    c = masked_array
    c[] = c.flip(0)
    assert_equal([4.0, 3.0, UNDEF, 1.0], c.to_a)
    c = masked_array
    c[0..2] = c[1..3]
    assert_equal([UNDEF, 3.0, 4.0, 4.0], c.to_a)
  end

  def test_store_without_mask_clears_the_destination_mask
    c = masked_array
    c[] = CA_FLOAT64([5, 6, 7, 8])
    assert_equal([false] * 4, c.is_masked.to_a)
    c = masked_array
    c[] = CA_INT32([5, 6, 7, 8])
    assert_equal([5.0, 6.0, 7.0, 8.0], c.to_a)
  end

  # ---- a lazy result's mask ----

  def test_lazy_result_mask_does_not_write_into_the_operand
    a = CA_FLOAT64([1, 2, 3, 4])
    a[1] = UNDEF
    b = CA_FLOAT64([10, 20, 30, 40])
    [a.lazy + b.lazy, a.lazy.sqrt, a.lazy.fma(1.0, 1.0), a.lazy].each do |r|
      assert_raise(RuntimeError) { r.mask[2] = 1 }
      assert_equal([false, true, false, false], a.is_masked.to_a)
    end
  end

  # ---- cells that would raise are skipped where masked ----

  def test_integer_ops_skip_a_masked_zero
    a = CA_INT32([2, 0, 3])
    a[1] = UNDEF
    e = CA_INT32([1, -1, 2])
    assert_parity(a ** e,          a.lazy ** e.lazy)
    assert_parity(a ** -3,         a.lazy ** -3)
    assert_parity(a.rcp_mul(e),    a.lazy.rcp_mul(e.lazy))
    assert_parity(a.rcp,           a.lazy.rcp)
    assert_parity(CA_INT8([2, 0, 3]).tap { |x| x[1] = UNDEF } ** CA_INT8([1, -1, 2]),
                  CA_INT8([2, 0, 3]).tap { |x| x[1] = UNDEF }.lazy ** CA_INT8([1, -1, 2]).lazy)
  end

  def test_object_ops_skip_masked_cells
    o = CA_OBJECT([1, 0, 2])
    o[1] = UNDEF
    four = CA_OBJECT([4, 4, 4])
    assert_parity(four / o,  four.lazy / o.lazy)
    assert_parity(four % o,  four.lazy % o.lazy)
    assert_parity(o.rcp,     o.lazy.rcp)
    s = CA_OBJECT(["a", nil, "c"])
    s[1] = UNDEF
    assert_parity(s + "x",   s.lazy + "x")
    assert_parity(s > "b",   s.lazy > "b")
    assert_parity(s.pmax("b"), s.lazy.pmax("b"))
  end

  # ---- boolean as 0/1 numeric ----

  def test_boolean_arithmetic_reads_as_int64
    b = CA_BOOLEAN([1, 0, 1])
    c = CA_BOOLEAN([1, 1, 0])
    %i[+ - * ** pmax pmin].each do |op|
      assert_parity(b.send(op, c), b.lazy.send(op, c.lazy))
    end
    one = CA_BOOLEAN([1, 1, 1])
    %i[/ % fmod].each do |op|
      assert_parity(b.send(op, one), b.lazy.send(op, one.lazy))
    end
    assert_parity(b + true,  b.lazy + true)
    assert_parity(-b,        -b.lazy)
    assert_parity(b.floor,   b.lazy.floor)
    assert_parity(b.square,  b.lazy.square)
    assert_parity(b.imag,    b.lazy.imag)
    assert_parity(b.fma(c, b), b.lazy.fma(c.lazy, b.lazy))
  end

  def test_boolean_logic_stays_boolean
    b = CA_BOOLEAN([1, 0, 1])
    c = CA_BOOLEAN([1, 1, 0])
    assert_parity(b & c, b.lazy & c.lazy)
    assert_parity(b ^ c, b.lazy ^ c.lazy)
  end

  def test_boolean_math_function_wants_a_cast
    b = CA_BOOLEAN([1, 0, 1])
    %i[sqrt sin exp log abs arg].each do |op|
      assert_raise(CArray::DataTypeError, op.to_s) { b.send(op) }
      assert_raise(CArray::DataTypeError, op.to_s) { b.lazy.send(op) }
    end
  end

  # ---- small ones ----

  def test_float32_arg_is_rounded_as_eager
    f = CA_FLOAT32([-1.5, 2.0, -0.0])
    assert_parity(f.arg, f.lazy.arg)
  end

  def test_fixlen_arithmetic_raises_as_eager
    x = fixlen(%w[abcd abcd abcd])
    assert_raise(CArray::DataTypeError) { x + x }
    assert_raise(CArray::DataTypeError) { x.lazy + x.lazy }
    assert_raise(CArray::DataTypeError) { -x }
    assert_raise(CArray::DataTypeError) { -x.lazy }
    assert_raise(CArray::DataTypeError) { x.lazy.sqrt }
    assert_raise(CArray::DataTypeError) { x.lazy.fma(x.lazy, x.lazy) }
  end

  # ---- a Face stays eager ----

  def test_face_lazy_returns_self
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
    assert_same(t, t.lazy)
    a = CA_FLOAT64([1, 2, 3])
    assert_kind_of(CALazyMarker, a.lazy)
  end

  def test_face_expressions_written_lazily_give_the_eager_answer
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
    h = CArray.time(["2024-01-01 00:00", "2024-01-02 00:00",
                     "2024-01-03 12:00"], unit: :h)
    assert_equal((t - t).class, (t.lazy - t.lazy).class)
    assert_equal((t > t[0]).to_a, (t.lazy > t[0]).to_a)
    assert_equal(t.eq(t).to_a, t.lazy.eq(t.lazy).to_a)
    assert_equal((t - t).class, CArray.fuse { t - t }.class)
    assert_raise(ArgumentError) { t < h }
    assert_raise(ArgumentError) { t.lazy < h.lazy }
  end

  # ---- imag of a non-complex array ----

  def test_imag_keeps_the_mask
    [CA_FLOAT64([1, 2, 3]), CA_INT32([1, -2, 3])].each do |a|
      a[1] = UNDEF
      assert_equal([false, true, false], a.imag.is_masked.to_a)
      assert_parity(a.imag, a.lazy.imag)
    end
  end

  def test_imag_of_object_takes_each_imaginary
    o = CA_OBJECT([Complex(1, 2), 3, Rational(1, 2)])
    assert_equal([2, 0, 0], o.imag.to_a)
    assert_parity(o.imag, o.lazy.imag)
  end

end
