require "test/unit"
require "carray"

# A view's cells need not be aligned to their size: a refer with a byte
# offset, or a struct member at an odd offset.  Every kernel reads them
# through an unaligned cell type, so the answers match an aligned copy (and
# a sanitizer build reports nothing).
class TestUnalignedCells < Test::Unit::TestCase

  TYPES = { CA_FLOAT64 => 8, CA_FLOAT32 => 4, CA_INT16 => 2, CA_INT32 => 4,
            CA_INT64 => 8, CA_CMPLX128 => 16 }

  def unaligned (t, n)
    v = CArray.uint8(TYPES[t] * n + 16).refer(t, [n], offset: 1)
    v[] = CArray.new(t, [n]) { |i| (i * 7) % 23 - 11 }
    v
  end

  def field (t, n)
    f = CArray.new(CA_FIXLEN, [n], bytes: TYPES[t] + 3).field(1, t)
    f[] = CArray.new(t, [n]) { |i| (i * 5) % 17 - 8 }
    f
  end

  def check (v)
    a = v.to_ca
    assert_equal a.to_a, v.to_a
    assert_equal (a + 1).to_a, (v + 1).to_a
    assert_equal (a * a).to_a, (v * v).to_a
    assert_equal a.sum, v.sum
    assert_equal a.to_type(CA_FLOAT64).to_a, v.to_type(CA_FLOAT64).to_a
    return if a.complex?
    assert_equal a.max, v.max
    assert_equal a.cumsum.to_a, v.cumsum.to_a
    assert_equal a.sort_addr.to_a, v.sort_addr.to_a
    assert_equal a.unique.to_a, v.unique.to_a
    assert_equal a.search(a[3]), v.search(v[3])
  end

  def test_a_refer_at_a_byte_offset_answers_as_an_aligned_copy
    TYPES.each_key { |t| check(unaligned(t, 45)) }
  end

  def test_a_struct_member_at_an_odd_offset_answers_as_an_aligned_copy
    TYPES.each_key { |t| check(field(t, 45)) }
  end

  def test_a_write_through_an_unaligned_view_lands
    v = unaligned(CA_FLOAT64, 9)
    v[] = 2.5
    assert_equal [2.5] * 9, v.to_a
    v.seq!(1)
    assert_equal (1..9).map(&:to_f), v.to_a
    v[v < 4] = 0
    assert_equal [0, 0, 0] + (4..9).map(&:to_f), v.to_a
  end

end
