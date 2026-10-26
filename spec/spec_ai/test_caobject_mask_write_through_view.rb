require 'test/unit'
require 'carray'

# A mask written through a view onto a CAObject whose mask lives in its
# mask hooks reaches the hooks, whatever view it goes through.
class TestCAObjectMaskWriteThroughView < Test::Unit::TestCase

  class Hooked < CAObject
    attr_reader :bits
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

  def object
    Hooked.new(CArray.float64(3, 4).seq)
  end

  # The same write on a plain array gives the expected bits.
  def expected
    r = CArray.float64(3, 4).seq
    yield r
    r.is_masked.to_a
  end

  VIEWS = {
    "grid"   => ->(o) { o[CA_INT([0, 2]), nil] },
    "grid2"  => ->(o) { o[CA_INT([0, 2]), CA_INT([1, 3])] },
    "select" => ->(o) { o[o.value.gt(5)] },
    "block"  => ->(o) { o[0..1, nil] },
  }

  def test_mask_assignment_through_a_view
    VIEWS.each do |name, view|
      o = object
      v = view.call(o)
      bits = CArray.boolean(*v.shape)
      bits[0] = 1
      v.mask = bits
      r_expected = expected { |r| u = view.call(r); u.mask = bits }
      assert_equal r_expected, o.bits.to_a, name
      assert_equal r_expected, o.is_masked.to_a, name
    end
  end

  def test_store_of_a_masked_array_through_a_view
    VIEWS.each do |name, view|
      o = object
      v = view.call(o)
      x = CArray.float64(*v.shape).seq
      x[0] = UNDEF
      v[] = x
      r_expected = expected { |r| view.call(r)[] = x }
      assert_equal r_expected, o.bits.to_a, name
    end
  end

  def test_clearing_a_masked_cell_through_a_view
    VIEWS.each do |name, view|
      o = object
      o[0, 0] = UNDEF
      o[2, 1] = UNDEF
      v = view.call(o)
      x = CArray.float64(*v.shape).seq
      v[] = x
      r_expected = expected { |r| r[0, 0] = UNDEF; r[2, 1] = UNDEF; view.call(r)[] = x }
      assert_equal r_expected, o.bits.to_a, name
    end
  end

  # unmask(method:) stores the filled cells through a selection.
  def test_unmask_by_method
    o = object
    r = CArray.float64(3, 4).seq
    [o, r].each do |t|
      t[0, 3] = UNDEF
      t[1, 2] = UNDEF
      t.unmask(method: :forward, axis: 0)
    end
    assert_equal r.is_masked.to_a, o.bits.to_a
    assert_equal r.value.to_a, o.value.to_a
  end
end
