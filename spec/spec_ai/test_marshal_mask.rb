require 'test/unit'
require 'carray'

# A mask marshals as a plain boolean array holding its bits, as a view's
# mask already does; the copy owns its memory and is independent of the
# array the mask belongs to.
class TestMarshalMask < Test::Unit::TestCase

  def array
    a = CArray.int32(4).seq
    a[1] = UNDEF
    a
  end

  MASKS = {
    "entity"     => ->(a) { a.mask },
    "fake"       => ->(a) { a.fake(:uint32).mask },
    "swap_bytes" => ->(a) { a.swap_bytes.mask },
    "lazy"       => ->(a) { (a.lazy + 1).mask },
    "time"       => ->(a) { a.time(unit: :s).mask },
    "dup"        => ->(a) { a.mask.dup },
    "transpose"  => ->(a) { a.transpose.mask },
  }

  def test_round_trip
    MASKS.each do |name, mask|
      a = array
      m = Marshal.load(Marshal.dump(mask.call(a)))
      assert_equal CArray, m.class, name
      assert_equal CA_BOOLEAN, m.data_type, name
      assert_equal [false, true, false, false], m.to_a, name
      m[0] = 1
      assert_equal [false, true, false, false], a.is_masked.to_a, name
    end
  end

  class Hooked < CAObject
    def initialize (buf)
      @buf  = buf
      @bits = CArray.boolean(*buf.shape)
      @bits[] = 0
      super(buf.data_type, buf.shape)
      self.mask = 0
    end
    def create_mask ; end
    def fetch_addr (a)          = @buf[a]
    def store_addr (a, v)       = @buf[a] = v
    def copy_data (d)           = d[] = @buf
    def sync_data (d)           = @buf[] = d
    def mask_copy_data (d)      = d[] = @bits
    def mask_sync_data (d)      = @bits[] = d
    def mask_fetch_addr (a)     = @bits[a]
    def mask_store_addr (a, v)  = @bits[a] = v
  end

  def test_object_arrays
    a = CArray.object(3).seq
    a[2] = UNDEF
    assert_equal [false, false, true], Marshal.load(Marshal.dump(a.mask)).to_a
    o = Hooked.new(CArray.int32(3).seq)
    o[1] = UNDEF
    assert_equal [false, true, false], Marshal.load(Marshal.dump(o.mask)).to_a
  end
end
