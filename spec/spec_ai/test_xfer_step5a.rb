require 'carray'
require 'test/unit'

# PROPOSAL_XFER_PROTOCOL step 5a (CAObject 再実装): CAObject / CAObjectMask gain
# xfer_index / xfer_addrs / xfer_stride / xfer_all (per-element Ruby callback
# bridge), severing their dependency on the legacy fetch_*/store_*/copy_data/
# sync_data slots so step 5b is a pure deletion.  These pin the new code paths:
#   - xfer_all   : whole-view to_ca (GET) + whole-view assignment (PUT)
#   - xfer_stride: a strided sub-view (CABlock over a CAObject) round-trips via
#                  the step 3b partial-materialise wiring -> CAObject xfer_stride
#   - xfer_addrs : a[mask] (CASelect over a CAObject) gathers via xfer_addrs
#   - xfer_index : per-cell [] / []=
class TestXferStep5a < Test::Unit::TestCase

  # CAObject backed by a plain Ruby Array; addr-primary callbacks.
  class AddrObj < CAObject
    def initialize(backing)
      super(CA_INT32, [backing.size])
      @backing = backing.dup
    end
    def fetch_addr(addr); @backing[addr]; end
    def store_addr(addr, val); @backing[addr] = val; end
    attr_reader :backing
  end

  # CAObject with index-primary callbacks (exercises the index core + the
  # addr->index fallback in xfer_addr_one).
  class IndexObj < CAObject
    def initialize(rows, cols)
      super(CA_INT32, [rows, cols])
      @h = {}
    end
    def fetch_index(idx); @h[idx.dup] || 0; end
    def store_index(idx, val); @h[idx.dup] = val; end
  end

  def test_xfer_all_get_to_ca
    o = AddrObj.new([10, 20, 30, 40, 50])
    assert_equal [10, 20, 30, 40, 50], o.copy.to_a
  end

  def test_xfer_index_percell
    o = AddrObj.new([10, 20, 30, 40, 50])
    assert_equal 30, o[2]
    o[2] = 99
    assert_equal 99, o.backing[2]
  end

  def test_xfer_index_2d
    o = IndexObj.new(2, 3)
    o[1, 2] = 7
    assert_equal 7, o[1, 2]
    assert_equal 0, o[0, 0]
    assert_equal [[0, 0, 0], [0, 0, 7]], o.copy.to_a
  end

  def test_xfer_stride_block_read
    # CABlock over CAObject: compose stops at the CAObject boundary and
    # partial-materialises the region through CAObject#xfer_stride.
    o = AddrObj.new([10, 20, 30, 40, 50])
    v = o[1..3]
    assert_equal CABlock, v.class
    assert_equal [20, 30, 40], v.copy.to_a
  end

  def test_xfer_stride_block_write
    o = AddrObj.new([10, 20, 30, 40, 50])
    o[1..3] = CArray.int32(3) { -1 }
    assert_equal [10, -1, -1, -1, 50], o.backing
  end

  def test_xfer_addrs_select_read
    # CASelect over CAObject: gathers via the parent's xfer_addrs.
    o = AddrObj.new([10, 20, 30, 40, 50])
    m = CArray.int32(5).seq.gt(2)        # [f,f,f,t,t]
    assert_equal [40, 50], o[m].copy.to_a
  end

  def test_xfer_addrs_select_write
    o = AddrObj.new([10, 20, 30, 40, 50])
    m = CArray.int32(5).seq.gt(2)
    o[m] = CArray.int32(2) { 99 }
    assert_equal [10, 20, 30, 99, 99], o.backing
  end

  def test_xfer_all_put_whole_view_assign
    o = AddrObj.new([0, 0, 0, 0])
    o[nil] = CArray.int32(4).tap { |x| x[] = (x.seq + 1) * 11 }
    assert_equal [11, 22, 33, 44], o.backing
  end

  # CA_UNDEF -> mask auto-generation (exercises the mask branch in the cores
  # and the objmask attach/copy through to_ca).
  class UndefObj < CAObject
    def initialize; super(CA_INT32, [4]); end
    def fetch_addr(addr); addr.odd? ? UNDEF : addr * 10; end
    def create_mask; end   # CAObject requires create_mask override for masking
  end

  def test_undef_creates_mask
    o = UndefObj.new
    r = o.copy
    assert_equal [false, true, false, true], r.mask.to_a
    assert_equal [0, 20], r[r.mask.eq(0)].to_a   # unmasked values intact
  end
end
