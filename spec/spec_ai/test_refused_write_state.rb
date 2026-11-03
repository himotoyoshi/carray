require "test/unit"
require "carray"

# A write that is refused leaves what it would have written as it was.
class TestRefusedWriteState < Test::Unit::TestCase

  class NoMaskObject < CAObject
    def initialize (back)
      @back = back
      super(back.data_type, back.shape)
    end
    private
    def fetch_addr (a) = @back[a]
    def store_addr (a, v) = (@back[a] = v)
  end

  class RefusingObject < CAObject
    def initialize (back)
      @back = back
      super(back.data_type, back.shape)
    end
    def create_mask; end
    private
    def fetch_addr (a) = @back[a]
    def store_addr (a, v) = raise(ArgumentError, "refused")
  end

  def test_index_store_of_a_value_that_does_not_fit_keeps_the_mask
    a = CArray.int8(4).seq!
    a[1] = UNDEF
    assert_raise(RangeError) { a[1] = 1000 }
    assert_equal [0, UNDEF, 2, 3], a.to_a
  end

  def test_index_store_of_a_value_of_the_wrong_kind_keeps_the_mask
    a = CArray.float64(4).seq!
    a[1] = UNDEF
    assert_raise(ArgumentError) { a[1] = "x" }
    assert_equal [0.0, UNDEF, 2.0, 3.0], a.to_a
  end

  def test_boolean_cell_keeps_the_mask
    a = CArray.boolean(4)
    a[1] = UNDEF
    assert_raise(CArray::DataTypeError) { a[1] = 44 }
    assert_equal true, a.is_masked[1]
  end

  def test_multi_index_store_keeps_the_mask
    a = CArray.int8(2, 2).seq!
    a[1, 0] = UNDEF
    assert_raise(RangeError) { a[1, 0] = 1000 }
    assert_equal [[0, 1], [UNDEF, 3]], a.to_a
  end

  def test_store_through_a_view_keeps_the_mask
    a = CArray.int8(4).seq!
    a[1] = UNDEF
    assert_raise(RangeError) { a.flip(0)[2] = 1000 }
    assert_equal [0, UNDEF, 2, 3], a.to_a
  end

  def test_refused_store_hook_keeps_the_mask
    o = RefusingObject.new(CArray.int32(3).seq!)
    o[1] = UNDEF
    assert_raise(ArgumentError) { o[1] = 5 }
    assert_equal [0, UNDEF, 2], o.to_a
  end

  def test_refused_mask_write_leaves_no_mask_on_a_stack
    c = NoMaskObject.new(CArray.int32(2, 3).seq!)
    s = CArray.stack([c, c.flip(0)])
    assert_raise(TypeError) { s.invert_mask }
    assert_false s.has_mask? && s.any_masked?
    assert_equal [[[0, 1, 2], [3, 4, 5]], [[3, 4, 5], [0, 1, 2]]], s.to_a
  end

  def test_refused_mask_write_leaves_no_mask_on_a_meld
    c = NoMaskObject.new(CArray.int32(2, 3).seq!)
    m = CArray.meld(c, c.flip(0), axis: 0)
    assert_raise(TypeError) { m.invert_mask }
    assert_equal [[0, 1, 2], [3, 4, 5], [3, 4, 5], [0, 1, 2]], m.to_a
  end

  def test_a_part_that_can_hold_a_mask_takes_the_write_when_another_refuses
    c = NoMaskObject.new(CArray.int32(3).seq!)
    a = CArray.int32(3).seq!
    s = CArray.stack([c, a])
    assert_raise(TypeError) { s.mask = 1 }
    assert_equal [UNDEF, UNDEF, UNDEF], a.to_a
    assert_equal [0, 1, 2], c.to_a
  end

end
