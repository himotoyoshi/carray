# Reading a view asks its source for the cells the view covers, however
# the view is reached and whatever it sits on.  An operand is read through
# its attach or its transfers, and either one must stay inside the view's
# footprint: a few cells picked out of a view over a computed root (a
# CAObject over a file, a lazy expression) must not make the root produce
# all of itself.
#
# Every view class carray defines is listed below as an intermediate
# parent, with a recipe that builds it over a root that counts the cells it
# is asked for, or with the reason it cannot be built there.  A new view
# class fails test_every_view_class_is_listed until it is added.  Small
# views of several shapes are taken over each parent, read in the ways an
# operand is read, and checked against the same reads over a plain array.

require 'test/unit'
require 'carray'

class TestViewReadFootprint < Test::Unit::TestCase

  SHAPE = [60, 80]

  class Counter < CAObject
    def initialize (back)
      @back  = back
      @cells = 0
      super(back.data_type, back.shape, read_only: true)
    end

    attr_accessor :cells

    private

    def fetch_addr (addr)
      @cells += 1
      @back[addr]
    end

    def copy_data (data)
      @cells += @back.elements
      data[] = @back
    end

    def copy_block (starts, counts, steps, data)
      @cells += counts.to_a.inject(:*)
      data[] = @back[*starts.each_index.map { |k| [starts[k], counts[k], steps[k]] }]
    end

    def copy_addrs (addrs, data)
      @cells += addrs.elements
      data[] = @back[addrs]
    end
  end

  PARENTS = {
    CABlock      => ->(r) { r[0...60, 0...79] },
    CAStride     => ->(r) { r.transpose.reshape(60, 80) },
    CATranspose  => ->(r) { r.transpose },
    CARefer      => ->(r) { r.transpose.flatten },
    CAFarray     => ->(r) { r.farray },
    CARepeat     => ->(r) { r[0, nil].reshape(1, 80).broadcast_to(60, 80) },
    CASelect     => ->(r) { b = CArray.boolean(*SHAPE) { 1 }; b[0] = 0; r[b] },
    CASelectAxis => ->(r) { b = CArray.boolean(60) { 1 }; b[0] = 0; r[b, nil] },
    CAGrid       => ->(r) { r[CArray.int64(59).seq(1), nil] },
    CARoll       => ->(r) { r.roll(1, 1) },
    CAShift      => ->(r) { r.shift(1, 1) },
    CAWindow     => ->(r) { r.window(-1..58, nil) },
    CATile       => ->(r) { r.tile(2, 1) },
    CAStack      => ->(r) { CArray.stack([r, r]) },
    CAMeld       => ->(r) { CArray.meld(r, r) },
    CARemap      => ->(r) { r.sort(axis: 1) },
    CAFake       => ->(r) { r.fake(CA_INT64) },
    CABitarray   => ->(r) { r.bitarray },
    CABitfield   => ->(r) { r.bitfield(0..3) },
    CAField      => ->(r) { r.field(0, CA_INT16) },
    CALazyMarker => ->(r) { r.lazy },
    CAMonOp      => ->(r) { -(r.lazy) },
    CABinOp      => ->(r) { r.lazy * 2 },
    CATriOp      => ->(r) { r.lazy.fma(r.lazy, r.lazy) },
    CAMonCmp     => ->(r) { r.lazy.is_finite },
    CABinCmp     => ->(r) { r.lazy > 3 },
  }

  NOT_A_PARENT = {
    CAObject         => "the counting root is one",
    CACategorical    => "a CAObject whose cells are codes",
    CAByteSwap       => "built only over struct and fixlen cells",
    CAMaskOfOperands => "the mask of a lazy expression, read with its expression",
    CAReduce         => "a mask view, read with the array it belongs to",
  }

  # Each recipe reads its root once per operand; the lazy fma has three.
  READS_PER_CELL = 3

  # Leading axes beyond the last two are fixed at 0.
  def self.lead (m)
    [0] * (m.ndim - 2)
  end

  TOPS = {
    "block" => ->(m) { m.ndim == 1 ? m[100...120] : m[*lead(m), 10...14, 20...25] },
    "grid"  => ->(m) { m.ndim == 1 ? m[CA_INT64([3, 1, 2])] : m[*lead(m), CA_INT64([1, 4]), CA_INT64([2, 5])] },
    "mask"  => ->(m) { b = CArray.boolean(*m.shape); b[0] = 1; b[7] = 1; m[b] },
    "flat"  => ->(m) { (m.ndim == 1 ? m[100...120] : m[*lead(m), 10...14, 20...25]).transpose.flatten },
  }

  READS = {
    "copy"  => ->(v) { v.copy.to_a },
    "+ 1"   => ->(v) { (v + 1).to_a },
    "sum"   => ->(v) { v.sum },
    "to_a"  => ->(v) { v.to_a },
  }

  def back
    @back ||= CArray.int32(*SHAPE) { |i| i * 7919 % 100003 }
  end

  def carray_view_classes
    bundle = $LOADED_FEATURES.grep(/carray_ext\./).first
    ObjectSpace.each_object(Class).select { |c|
      next false unless c < CAView && c.name && !c.name.include?("::")
      next false if c <= CAFace || c.name.end_with?("Mask")
      loc = Object.const_source_location(c.name)
      loc && (loc[0] == bundle || loc[0].include?("/lib/carray/"))
    }
  end

  def test_every_view_class_is_listed
    missing = carray_view_classes.reject { |c| PARENTS.key?(c) || NOT_A_PARENT.key?(c) }
    assert_equal([], missing.map(&:name).sort,
                 "add a recipe that builds it over a root, or the reason it cannot be one")
  end

  def test_recipes_build_their_class
    PARENTS.each do |klass, recipe|
      assert_kind_of(klass, recipe.(back), klass.name)
    end
  end

  def test_reads_stay_inside_the_view
    PARENTS.each do |klass, recipe|
      TOPS.each do |tname, top|
        READS.each do |rname, read|
          root = Counter.new(back)
          view = top.(recipe.(root))
          root.cells = 0
          got = read.(view)
          where = "#{rname} of a #{tname} view over #{klass.name}"
          assert_equal(read.(top.(recipe.(back))), got, where)
          assert_operator(root.cells, :<=, READS_PER_CELL * view.elements,
                          "#{where} asked its root for #{root.cells} cells")
        end
      end
    end
  end

  # The same chains written through a computed root that takes writes:
  # whether the root lends memory decides which path a write takes, and
  # every path must land the written cells and only those.
  class Writable < CAObject
    attr_reader :back

    def initialize (back)
      @back = back
      super(back.data_type, back.shape)
    end

    private

    def fetch_addr (addr)
      @back[addr]
    end

    def store_addr (addr, value)
      @back[addr] = value
    end
  end

  WRITES = {
    "a reshape over a transpose" => ->(r) { r.transpose.reshape(6, 8)[1...3, 2...5] = CArray.int32(2, 3).seq },
    "a flattened transpose"      => ->(r) { r.transpose.flatten[CA_INT64([3, 1, 2])] = 9 },
    "a masked flattened transpose" => ->(r) { b = CArray.boolean(48); b[5] = 1; b[9] = 1; r.transpose.flatten[b] = CA_INT32([4, 5]) },
    "an in-place add"            => ->(r) { r.transpose.reshape(6, 8)[1...3, 2...5].add!(10) },
    "a field"                    => ->(r) { r.field(0, CA_INT16)[1...3, 2...5] = 3 },
  }

  def test_writes_through_the_same_chains_land
    WRITES.each do |name, write|
      plain = CArray.int32(8, 6) { |i| i }
      root  = Writable.new(CArray.int32(8, 6) { |i| i })
      write.(plain)
      write.(root)
      assert_equal(plain.to_a, root.back.to_a, name)
    end
  end

end
