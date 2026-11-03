require "test/unit"
require "carray"

# The map! family writes in the receiver's attach window.  What it writes
# reaches the root through every view.
class TestMapFamilyThroughViews < Test::Unit::TestCase

  class Cold < CAObject
    attr_reader :back
    def initialize (b) = (@back = b; super(b.data_type, b.shape))
    private
    def fetch_addr (a) = @back[a]
    def store_addr (a, v) = (@back[a] = v)
  end

  VIEWS = {
    "grid" => ->(x) { x[CA_INT64([1, 0]), nil] },
    "select" => ->(x) { x[x.ge(0)] },
    "addresses" => ->(x) { x[CA_INT64([0, 3, 5])] },
    "window" => ->(x) { x.window(0..1, 0..1) },
    "roll" => ->(x) { x.roll(1, 0) },
    "tile" => ->(x) { x.tile(1, 1) },
    "stack" => ->(x) { CArray.stack([x, x.flip(0)]) },
    "meld" => ->(x) { CArray.meld(x, x.flip(0), axis: 0) },
    "sort" => ->(x) { x.sort(axis: 1) },
    "fake" => ->(x) { x.fake(:float64) },
  }.freeze

  def root = CArray.int32(2, 3).seq!

  def test_map_index_reaches_the_root
    VIEWS.each { |name, make|
      x = root
      v = make.call(x)
      v.map_index! { |*i| 9 }
      assert_equal [9] * v.elements, v.to_a.flatten, name
    }
  end

  def test_map_with_index_reaches_the_root
    VIEWS.each { |name, make|
      x = root
      v = make.call(x)
      v.map_with_index! { |*i| 9 }
      assert_equal [9] * v.elements, v.to_a.flatten, name
    }
  end

  def test_map_index_on_a_caobject
    c = Cold.new(root)
    c.map_index! { |i, j| 9 }
    assert_equal [[9, 9, 9], [9, 9, 9]], c.back.to_a
    c.map_with_index! { |e, i, j| e + i + j }
    assert_equal [[9, 10, 11], [10, 11, 12]], c.back.to_a
  end

  def test_undef_through_a_window_over_a_view_without_a_mask
    x = root
    x.flip(0).window(0..1, 0..1).map! { |e| UNDEF }
    assert_equal [[UNDEF, UNDEF, 2], [UNDEF, UNDEF, 5]], x.to_a
  end

  def test_undef_through_a_shift_over_a_view_without_a_mask
    x = root
    x.flip(0).shift(0, 0).map! { |e| UNDEF }
    assert_equal [[UNDEF] * 3] * 2, x.to_a
  end

  def test_some_cells_undef
    x = root
    x.transpose(1, 0).window(0..2, 0..1).map_addr! { |a| a == 0 ? UNDEF : 5 }
    assert_equal [[UNDEF, 5, 5], [5, 5, 5]], x.to_a
  end

  def test_the_construction_block_still_works
    assert_equal [[0, 1], [10, 11]], CArray.int32(2, 2) { |i, j| i * 10 + j }.to_a
  end

  # A view whose chain ends in a buffer of its own in a parent further up:
  # the mask made inside the window has that buffer too.

  def over_a_reshaped_flip (root)
    root.flip(0).reshape(6).window(0..5)
  end

  def test_undef_from_map_reaches_a_root_past_a_held_buffer
    x = CArray.int64(2, 3).seq!
    over_a_reshaped_flip(x).reverse.map! { UNDEF }
    assert_equal 6, x.count_masked
  end

  def test_undef_from_map_reaches_a_root_past_a_held_buffer_through_a_shift
    x = CArray.int64(2, 3).seq!
    x.flip(0).reshape(6).shift(0).reverse.map! { UNDEF }
    assert_equal 6, x.count_masked
  end

  def test_undef_in_a_ruby_array_reaches_a_root_past_a_held_buffer
    x = CArray.int64(2, 3).seq!
    over_a_reshaped_flip(x).reverse[] = [1, UNDEF, 3, UNDEF, 5, UNDEF]
    assert_equal 3, x.count_masked
  end

  def test_some_cells_of_a_map_stay_as_values_past_a_held_buffer
    x = CArray.int64(2, 3).seq!
    v = over_a_reshaped_flip(x).reverse
    v.map! { |e| e.even? ? UNDEF : e }
    e = CArray.int64(2, 3).seq!
    w = over_a_reshaped_flip(e).reverse
    w.to_a.each_with_index { |c, i| w[i] = UNDEF if c.even? }
    assert_equal e.to_a, x.to_a
  end

end
