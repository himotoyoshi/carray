require "test/unit"
require "carray"

# CARecord.wrap of a record array (another struct over the same bytes) wraps
# its storage, so the result is not a Face over a Face.
class TestCARecordWrapRecord < Test::Unit::TestCase

  P = CArray.struct { float64 :a; float64 :b }
  Q = CArray.struct { float64 :x; float64 :y }

  def records
    r = CARecord.wrap(CArray.new(CA_FIXLEN, [2], bytes: 16), P)
    r[0] = P.new(a: 1.0, b: 2.0)
    r
  end

  def test_wraps_the_storage
    r = records
    w = CARecord.wrap(r, Q)
    assert_false w.send(:face_storage).face?
    assert_same r.send(:face_storage), w.send(:face_storage)
    assert_equal [1.0, 2.0], [w[0].x, w[0].y]
  end

  def test_writes_reach_the_bytes_both_read
    r = records
    w = CARecord.wrap(r, Q)
    w[1] = Q.new(x: 5.0, y: 6.0)
    assert_equal 5.0, r[1].a
  end

  def test_a_view_of_records
    w = CARecord.wrap(records[0..0], Q)
    assert_false w.send(:face_storage).face?
    assert_equal 1.0, w[0].x
  end

end
