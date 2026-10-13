$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# The methods that order cells by hand -- nlargest / nsmallest, partition,
# sort_by_key, max_by_key / min_by_key, range -- order a Face the way its
# own sort does.  CAConstString's storage is offsets and a record's is its
# bytes; neither is an order of the values.

module FaceOrderAgreement

  # Each Face, how to read a value out of its answer, and the array of the
  # same values sort orders.
  def faces
    st = CArray.struct(pack: 1, order_by: [:id]) { int32 :id }
    rec = CARecord.new(st, 5)
    rec["id"] = CA_INT32([-1, 256, 2, 1, 300])
    {
      "CAConstString" => [CArray.const_string(%w[bb a ccc dd a]), ->(x) { x.to_a }],
      "CARecord"      => [rec, ->(x) { x["id"].to_a }],
      "CATime"        => [CArray.time(%w[2024-01-03 2024-01-01 2024-01-05 2024-01-02 2024-01-04], unit: :D),
                          ->(x) { x.to_a.map(&:to_s) }],
    }
  end

end

class TestTopkOrdersFaceAsSort < Test::Unit::TestCase
  include FaceOrderAgreement

  def test_nsmallest_and_nlargest
    faces.each do |name, (a, read)|
      sorted = read.(a.sort)
      (0..a.elements).each do |k|
        assert_equal sorted.first(k), read.(a.nsmallest(k)), "#{name} nsmallest(#{k})"
        assert_equal sorted.last(k).reverse, read.(a.nlargest(k)), "#{name} nlargest(#{k})"
      end
    end
  end

  def test_index_forms_pick_the_same_values
    faces.each do |name, (a, read)|
      sorted = read.(a.sort)
      idx = a.nlargest_index(3, axis: 0)
      assert_equal sorted.last(3).reverse, read.(a[idx]), "#{name} nlargest_index"
      idx = a.nsmallest_index(3, axis: 0)
      assert_equal sorted.first(3), read.(a[idx]), "#{name} nsmallest_index"
    end
  end

end

class TestPartitionOrdersFaceAsSort < Test::Unit::TestCase
  include FaceOrderAgreement

  def test_kth_cell_and_both_sides
    faces.each do |name, (a, read)|
      sorted = read.(a.sort)
      a.elements.times do |kth|
        [a.partition(kth), a.partition_copy(kth)].each do |pv|
          got = read.(pv)
          assert_equal sorted[kth], got[kth], "#{name} partition(#{kth})"
          assert_equal sorted.first(kth).sort_by(&:to_s), got.first(kth).sort_by(&:to_s),
                       "#{name} partition(#{kth}) left side"
        end
      end
    end
  end

end

class TestByKeyOrdersFaceAsSort < Test::Unit::TestCase
  include FaceOrderAgreement

  def test_sort_by_key
    faces.each do |name, (a, _read)|
      pos = CArray.int32(a.elements).seq
      assert_equal pos[a.sort_addr].to_a, pos.sort_by_key(a).to_a, name
    end
  end

  def test_max_and_min_by_key
    faces.each do |name, (a, read)|
      pos = CArray.int32(a.elements).seq
      assert_equal read.(a.sort).last,  read.(a[pos.max_by_key(a)..pos.max_by_key(a)]).first, "#{name} max"
      assert_equal read.(a.sort).first, read.(a[pos.min_by_key(a)..pos.min_by_key(a)]).first, "#{name} min"
    end
  end

  def test_range
    element = {
      "CAConstString" => ->(e) { e },
      "CARecord"      => ->(e) { e["id"] },
      "CATime"        => ->(e) { e.to_s },
    }
    faces.each do |name, (a, read)|
      sorted = read.(a.sort)
      r = a.range
      assert_equal [sorted.first, sorted.last],
                   [element[name].(r.begin), element[name].(r.end)], name
    end
  end

  def test_record_without_order_is_refused_everywhere
    st = CArray.struct(pack: 1) { int32 :id }
    q = CARecord.new(st, 3)
    q["id"] = CA_INT32([2, 1, 3])
    [-> { q.nsmallest(2) }, -> { q.nlargest(2) }, -> { q.partition(1) },
     -> { q.partition_copy(1) },
     -> { CA_INT32([0, 1, 2]).sort_by_key(q) },
     -> { CA_INT32([0, 1, 2]).max_by_key(q) }].each do |f|
      assert_raise(ArgumentError) { f.call }
    end
  end

end

class TestByKeyShapeAndEmpty < Test::Unit::TestCase

  def test_key_of_another_shape_is_refused
    a = CA_INT32([10, 20, 30, 40])
    assert_raise(ArgumentError) { a.sort_by_key(CA_FLOAT64([1, 0])) }
    assert_raise(ArgumentError) { a.max_by_key(CA_FLOAT64([1, 0])) }
    assert_raise(ArgumentError) { a.min_by_key(CA_FLOAT64([1, 0, 2, 3, 4])) }
  end

  # No cell to compare is UNDEF, not a raise.
  def test_all_masked_or_nan_key_is_undef
    k = CA_FLOAT64([1, 2])
    k[] = UNDEF
    assert_equal UNDEF, CA_INT32([1, 2]).max_by_key(k)
    assert_equal UNDEF, CA_INT32([1, 2]).min_by_key(k)
  end

  def test_empty_fibers_are_undef_cells
    got = CArray.int32(3, 0).max_by_key(CArray.float64(3, 0), axis: 1)
    assert_equal [UNDEF, UNDEF, UNDEF], got.to_a
  end

end
