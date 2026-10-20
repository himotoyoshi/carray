require "test/unit"
require "carray"
require "tmpdir"

# An unnamed struct's order_by survives save / load and Marshal: the struct
# rebuilt from the saved members declares the same order.  It came back
# with none, so the records could not be sorted.
class TestStructOrderByRoundtrip < Test::Unit::TestCase

  def records
    q = CArray.struct(order_by: [:b]) { float64 :a; float64 :b }
    r = CARecord.wrap(CArray.new(CA_FIXLEN, [3], bytes: 16), q)
    r[0] = q.new(a: 1.0, b: 3.0)
    r[1] = q.new(a: 2.0, b: 1.0)
    r[2] = q.new(a: 3.0, b: 2.0)
    r
  end

  def test_marshal
    m = Marshal.load(Marshal.dump(records))
    assert_equal ["b"], m.data_class.order_by
    assert_equal [1.0, 2.0, 3.0], m.sort.to_a.map(&:b)
  end

  def test_save_and_load
    path = File.join(Dir.tmpdir, "carray_order_by_#{$$}.ca")
    CArray.save(records, path)
    l = CArray.load(path)
    assert_equal ["b"], l.data_class.order_by
    assert_equal [1.0, 2.0, 3.0], l.sort.to_a.map(&:b)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_no_order_stays_none
    q = CArray.struct { float64 :a }
    r = CARecord.wrap(CArray.new(CA_FIXLEN, [1], bytes: 8), q)
    assert_nil Marshal.load(Marshal.dump(r)).data_class.order_by
  end

end
