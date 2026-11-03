require "test/unit"
require "carray"

# A slab of no cells is a view like another; a kernel attaches and detaches it.
class TestSlabOfAnEmptyView < Test::Unit::TestCase

  VIEWS = [->(a) { a.flatten }, ->(a) { a.flip(0) }, ->(a) { a[0...0] }].freeze

  def test_a_kernel_on_the_slab
    VIEWS.each { |make|
      v = make.call(CArray.int8(0))
      got = []
      v.each_slab(axis: 0) { |s| got << [s.sum, s.min, s.first] }
      assert_equal [[0.0, UNDEF, UNDEF]], got.map { |x| [x[0].to_f, x[1], x[2]] }
    }
  end

  def test_a_masked_view_of_no_rows
    a = CArray.int8(2, 3).seq!
    a[0, 0] = UNDEF
    v = a[[1, 0], nil]
    assert_equal [UNDEF, UNDEF, UNDEF], v.reduce_slab(axis: 0) { |s| s.first }.to_a
  end

  def test_a_masked_view_with_no_cells_along_the_slab
    a = CArray.int16(6, 1).seq!
    a[0, 0] = UNDEF
    v = a[nil, [1, 0]].dim_view(1, 0)
    assert_equal [UNDEF] * 6, v.reduce_slab(axis: 0) { |s| s.first }.to_a
  end

  def test_reduce_slab_answers_as_on_an_entity
    e = CArray.int8(0).reduce_slab(axis: 0) { |s| s.first }
    VIEWS.each { |make|
      v = make.call(CArray.int8(0))
      assert_equal e.to_a, v.reduce_slab(axis: 0) { |s| s.first }.to_a
    }
  end

end
