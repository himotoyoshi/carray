require "test/unit"
require "carray"

# map_slab and reduce_slab answer in a Face over fixlen storage, whose width the
# name of the type does not carry.
class TestSlabOverFixlenFaces < Test::Unit::TestCase

  S = CArray.struct(order_by: [:a]) { int32 :a; int32 :b }

  def record
    r = CARecord.new(S, 4)
    r["a"][] = CA_INT32([1, 2, 3, 4])
    r["b"][] = CA_INT32([5, 6, 7, 8])
    r
  end

  def test_map_slab_on_fixlen_strings
    f = CArray.fixlen_string(%w[ab cd ef gh]).reshape(2, 2)
    m = f.map_slab(axis: 0) { |s| s.flip(0).copy }
    assert_instance_of CAFixlenString, m
    assert_equal [["ef", "gh"], ["ab", "cd"]], m.to_a
    assert_equal 2, m.bytes
  end

  def test_reduce_slab_on_fixlen_strings
    f = CArray.fixlen_string(%w[ab cd ef gh]).reshape(2, 2)
    r = f.reduce_slab(axis: 0) { |s| s[1] }
    assert_instance_of CAFixlenString, r
    assert_equal %w[ef gh], r.to_a
  end

  def test_map_slab_on_records
    m = record.map_slab(axis: 0) { |s| s.flip(0).copy }
    assert_instance_of CARecord, m
    assert_equal [4, 3, 2, 1], m["a"].to_a
    assert_equal [8, 7, 6, 5], m["b"].to_a
  end

  def test_reduce_slab_on_records
    r = record.reduce_slab(axis: 0) { |s| s[0] }
    assert_equal 1, r[0].a
  end

  def test_a_masked_cell_stays_masked
    f = CArray.fixlen_string(%w[ab cd])
    f[1] = UNDEF
    assert_equal ["ab", UNDEF], f.map_slab(axis: 0) { |s| s.copy }.to_a
  end

end
