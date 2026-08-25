# Regression pin for T10-class silent write loss bug in ca_fake_func_xfer_all
# PUT direction (fixed 2026-05-31 in commit on master).
#
# Bug: CAFake.xfer_all PUT path did `ca_attach(parent) -> cast_block writes to
# parent->ptr -> ca_detach(parent)` without ca_sync(parent).  When parent is a
# cold boundary view (CASelect/CAGrid/CAReduce/CAWindow/...), ca_attach
# allocates scratch and gathers; cast_block writes to that scratch; ca_detach
# xfrees the scratch without sync.  Writes silently lost.
#
# Trigger: CAFake wrapping a boundary view, written via `view[] = src`.

require "test/unit"
require "carray"

class TestFakeXferAllPutSync < Test::Unit::TestCase
  def test_fake_over_caselect_put_propagates_to_entity
    a = CArray.float64(10).seq
    mask = CArray.boolean(10)
    10.times { |i| mask[i] = (i % 3 == 0) }   # 4 trues at 0,3,6,9

    fake = a[mask].fake(:int32)
    assert_equal 4, fake.elements

    src = CArray.int32(*fake.dim).seq + 100   # [100,101,102,103]
    fake[] = src

    # Expected: entity cells at masked positions updated to cast-back values.
    expected = [100.0, 1.0, 2.0, 101.0, 4.0, 5.0, 102.0, 7.0, 8.0, 103.0]
    assert_equal expected, a.to_a
  end

  def test_fake_over_cagrid_put_propagates_to_entity
    a = CArray.float64(2, 5).seq         # 0..9
    idx = CArray.int32(3).tap { |x| x[] = x.seq }  # [0,1,2]
    grid = a.grid(nil, idx).fake(:int32) # (2, 3) int32 view via CAGrid
    src = CArray.int32(*grid.dim).tap { |x| x[] = x.seq + 200 }
    grid[] = src
    # Entity cols 0..2 of each row should be 200..205 (cast back).
    expected = [[200.0, 201.0, 202.0, 3.0, 4.0],
                [203.0, 204.0, 205.0, 8.0, 9.0]]
    assert_equal expected, a.to_a
  end

  def test_fake_over_entity_put_unchanged_no_regression
    # Entity parent: ca_attach is no-op, ca->parent->ptr is live storage.
    # ca_sync(entity) is no-op too.  Verify fix didn't regress this common case.
    a = CArray.float64(5).seq
    fake = a.fake(:int32)
    src = CArray.int32(5).tap { |x| x[] = x.seq * 10 }
    fake[] = src
    assert_equal [0.0, 10.0, 20.0, 30.0, 40.0], a.to_a
  end
end
