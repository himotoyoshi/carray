# A CAObject's mask can live in Ruby: the mask_* hooks provide and receive
# its bits, the way copy_data / sync_data and fetch_addr / store_addr do for
# the values.  Whichever family an object answers -- the bulk pair or the
# per-cell pair -- every read has to come from it and every write has to
# reach it, through the mask itself (obj.mask[...] = ...), through the
# array (obj[...] = UNDEF, unmask), or through mask= .

require "test/unit"
require "carray"

class TestCAObjectMaskHooks < Test::Unit::TestCase

  # The values are 0, 1, 2, ...; the mask is whatever @bits says.
  class HookedMask < CAObject
    attr_reader :bits
    def initialize (bits)
      @src  = CArray.int32(bits.size).seq
      @bits = CArray.boolean(bits.size) { 0 }
      super(CA_INT32, [bits.size])
      self.mask = 0
      @bits[] = CA_BOOLEAN(bits)
    end
    def create_mask ; end
    def copy_data (d)     ; d[] = @src ; end
    def sync_data (d)     ; @src[] = d ; end
    def fetch_addr (a)    ; @src[a] ; end
    def store_addr (a, v) ; @src[a] = v ; end
  end

  class BulkMask < HookedMask
    def mask_copy_data (d) ; d[] = @bits ; end
    def mask_sync_data (d) ; @bits[] = d ; end
  end

  class CellMask < HookedMask
    def mask_fetch_addr (a)    ; @bits[a] ? 1 : 0 ; end
    def mask_store_addr (a, v) ; @bits[a] = v ; end
  end

  KINDS = { "bulk" => BulkMask, "per-cell" => CellMask }

  BITS   = ->(m) { m.to_a.map { |b| b ? 1 : 0 } }
  VALUES = ->(a) { a.to_a.map { |x| x == UNDEF ? :U : x } }

  def bits_of (m)   ; BITS.(m)   ; end
  def values_of (a) ; VALUES.(a) ; end

  READS = {
    "to_a"          => [->(o) { VALUES.(o) },           [:U, 1, 2, :U]],
    "mask.to_a"     => [->(o) { BITS.(o.mask) },        [1, 0, 0, 1]],
    "mask.copy"     => [->(o) { BITS.(o.mask.copy) },   [1, 0, 0, 1]],
    "copy"          => [->(o) { VALUES.(o.copy) },      [:U, 1, 2, :U]],
    "is_masked"     => [->(o) { BITS.(o.is_masked) },   [1, 0, 0, 1]],
    "count_masked"  => [->(o) { o.count_masked },        2],
    "o + 0"         => [->(o) { VALUES.(o + 0) },        [:U, 1, 2, :U]],
    "o[1..3]"       => [->(o) { VALUES.(o[1..3]) },      [1, 2, :U]],
  }

  KINDS.each do |kind, klass|
    READS.each do |name, (read, expected)|
      define_method("test_#{kind}_mask_is_read_through_#{name.gsub(/\W+/, '_')}") do
        assert_equal expected, read.(klass.new([1, 0, 0, 1]))
      end
    end
  end

  WRITES = {
    "o[1] = UNDEF"             => [->(o) { o[1] = UNDEF },                     [1, 1, 0, 1]],
    "o[0..1] = UNDEF"          => [->(o) { o[0..1] = UNDEF },                  [1, 1, 0, 1]],
    "o.mask[2] = 1"            => [->(o) { o.mask[2] = 1 },                    [1, 0, 1, 1]],
    "o.mask[] = bits"          => [->(o) { o.mask[] = CA_BOOLEAN([0, 1, 1, 0]) }, [0, 1, 1, 0]],
    "o.mask=(bits)"            => [->(o) { o.mask = CA_BOOLEAN([0, 1, 1, 0]) },   [0, 1, 1, 0]],
    "o.mask.fill(1)"           => [->(o) { o.mask.fill(1) },                   [1, 1, 1, 1]],
    "o.unmask"                 => [->(o) { o.unmask },                         [0, 0, 0, 0]],
    "o.mask[addrs] = 1"        => [->(o) { o.mask[CA_SIZE([0, 2])] = 1 },      [1, 0, 1, 1]],
  }

  KINDS.each do |kind, klass|
    WRITES.each do |name, (write, expected)|
      define_method("test_#{kind}_mask_is_written_through_#{name.gsub(/\W+/, '_')}") do
        o = klass.new([1, 0, 0, 1])
        write.(o)
        assert_equal expected, bits_of(o.bits), "the hooks' bits"
        assert_equal expected, bits_of(o.mask), "read back"
      end
    end
  end

  # A fetcher that answers UNDEF masks the cell, as it always did.
  class UndefFetch < CAObject
    def initialize
      super(CA_INT32, [4])
    end
    def create_mask ; end
    def fetch_addr (a) ; a.odd? ? UNDEF : a * 10 ; end
  end

  def test_a_fetcher_answering_undef_masks_the_cell
    assert_equal [0, :U, 20, :U], values_of(UndefFetch.new)
  end

end
