require 'carray'
require 'test/unit'

# PROPOSAL_XFER_PROTOCOL step 4 (xfer_all): each view's copy_data / sync_data
# bodies are merged into the direction-unified xfer_all slot (copy_data /
# sync_data become thin forwarders).  Public ca_copy_data / ca_sync_data now
# route through ca_xfer_all.  This must stay value-equivalent across all
# migrated view families.
#
# GET goes through xfer_all when a whole view is materialised (.to_ca);
# PUT goes through it when a whole CArray of matching data_type is assigned into a
# view (carray_access.c -> ca_sync_data).  We pin both per view family.
class TestXferAll < Test::Unit::TestCase

  # ---- GET: view.to_ca must equal the ground truth ----

  def test_get_entity
    a = CArray.int32(4, 4).seq
    assert_equal a.to_a, a.to_ca.to_a
  end

  def test_get_stride_reshape
    a = CArray.int32(12).seq
    assert_equal [[0,1,2,3],[4,5,6,7],[8,9,10,11]], a.reshape(3, 4).to_ca.to_a
  end

  def test_get_stride_transpose
    a = CArray.int32(3, 4).seq
    assert_equal a[].transpose.to_a, a.transpose.to_ca.to_a
  end

  def test_get_stride_block
    a = CArray.int32(6, 5).seq
    assert_equal a[1..3, 1..2].to_a, a[1..3, 1..2].to_ca.to_a
  end

  def test_get_select
    a = CArray.int32(10).seq
    assert_equal [6, 7, 8, 9], a[a > 5].to_ca.to_a    # CASelect
  end

  def test_get_grid
    a = CArray.int32(4, 4).seq
    assert_equal [[1,2],[5,6],[9,10],[13,14]], a.grid(nil, 1..2).to_ca.to_a  # CAGrid
  end

  def test_get_window
    a = CArray.int32(5).seq
    assert_equal [1, 2, 3], a.window(1..3).to_ca.to_a  # CAWindow interior
  end

  def test_get_shift
    a = CArray.int32(5).seq
    v = a.shift(1)                    # CAShift (= CAWindow typedef)
    assert_equal v.to_a, v.to_ca.to_a
  end

  def test_get_tile
    a = CArray.int32(3).seq
    assert_equal [0, 1, 2, 0, 1, 2], a.tile(2).to_ca.to_a  # CATile
  end

  def test_get_roll
    a = CArray.int32(5).seq
    assert_equal [3, 4, 0, 1, 2], a.roll(2).to_ca.to_a     # CARoll
  end

  def test_get_fake
    f = CArray.float64(4).tap { |x| x[] = x.seq + 0.5 }
    assert_equal [0, 1, 2, 3], f.fake(:int32).to_ca.to_a   # CAFake value cast
  end

  def test_get_byteswap
    a = CArray.int32(4).seq
    v = a.swap_bytes                 # CAByteSwap
    assert_equal v.to_a, v.to_ca.to_a
  end

  # ---- PUT: whole-view CArray assignment must scatter back to the entity ----

  def test_put_stride_transpose
    a = CArray.int32(3, 4).seq
    a.transpose[nil, nil] = CArray.int32(4, 3) { -1 }
    assert_equal [-1] * 12, a.flatten.to_a
  end

  def test_put_stride_block
    a = CArray.int32(6, 5).seq
    a[1..3, 1..2][nil, nil] = CArray.int32(3, 2) { 99 }
    assert_equal [99, 99], a[1, 1..2].to_a
    assert_equal [99, 99], a[3, 1..2].to_a
    assert_equal 0, a[0, 0]          # outside the block untouched
  end

  def test_put_select
    a = CArray.int32(10).seq
    a[a > 5] = (CArray.int32(4).seq + 100)
    assert_equal [0,1,2,3,4,5,100,101,102,103], a.to_a
  end

  def test_put_grid
    a = CArray.int32(4, 4).seq
    a.grid(nil, 1..2)[nil, nil] = CArray.int32(4, 2) { -7 }
    assert_equal [0, -7, -7, 3], a[0, nil].to_a
    assert_equal [12, -7, -7, 15], a[3, nil].to_a
  end
end
