require "test/unit"
require "carray"

# A dup of a CAObject is another view of what the object reads: it shares
# the values and the mask, and outlives the original.  A copy_data of an
# object whose mask comes from its hooks may touch the mask while it runs;
# what it does through the hooks reaches the copy, and the copy is the same
# under a collection at every allocation.

class TestCAObjectDupAndHookMasks < Test::Unit::TestCase

  class Hooked < CAObject
    attr_accessor :action
    def initialize (back)
      @back = back
      @m = CArray.boolean(back.elements) { 0 }
      super(back.data_type, back.shape)
    end
    private
    def fetch_addr (a) = @back[a]
    def store_addr (a, v) = (@back[a] = v)
    def mask_fetch_addr (a) = @m[a]
    def mask_store_addr (a, v) = (@m[a] = v)
    def copy_data (d)
      d[] = @back
      if @action && ! @in
        @in = true
        @action.(self, d)
        @in = false
      end
    end
    def create_mask; end
  end

  def test_a_dup_shares_the_mask_and_outlives_the_original
    r = Hooked.new(CArray.float64(4).seq)
    r[1] = UNDEF
    d = r.dup
    d[2] = UNDEF
    assert_equal [false, true, true, false], r.is_masked.to_a
    r = nil
    GC.start
    GC.compact if GC.respond_to?(:compact)
    assert_equal [false, true, true, false], d.is_masked.to_a
    assert_equal [0.0, UNDEF, UNDEF, 3.0], d.to_a
  end

  def test_copy_data_touching_the_mask
    {
      ->(o, d) { o.mask }          => 1,
      ->(o, d) { o[0] = UNDEF }    => 2,
      ->(o, d) { o.unmask }        => 0,
      ->(o, d) { o.copy }          => 1,
      ->(o, d) { d[0] = UNDEF }    => 1,
      ->(o, d) { d.mask = 0 }      => 1,
    }.each do |action, masked|
      r = Hooked.new(CArray.float64(200).seq)
      r[1] = UNDEF
      r.action = action
      GC.stress = true
      c = r.copy
      GC.stress = false
      assert_equal masked, c.count_masked
      assert_equal masked, r.copy.count_masked
    end
  ensure
    GC.stress = false
  end

end
