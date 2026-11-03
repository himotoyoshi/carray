require "test/unit"
require "carray"

# A damaged object payload is refused before its shape is allocated: the
# shape is only a claim until the values are seen to fill it.
class TestMarshalObjectPayloadShape < Test::Unit::TestCase

  module AllocationSpy
    attr_accessor :allocations
    def object (*shape, &block)
      self.allocations = allocations.to_i + 1
      super
    end
  end

  def load_payload (data)
    CArray.allocate.marshal_load(data)
  end

  def assert_refused_before_allocating (data)
    CArray.singleton_class.prepend(AllocationSpy)
    CArray.allocations = 0
    assert_raise(ArgumentError) { load_payload(data) }
    assert_equal 0, CArray.allocations
  end

  def test_values_that_do_not_fill_the_shape
    assert_refused_before_allocating ["object", [4], [1, 2], nil, {}]
  end

  def test_nesting_that_does_not_match_the_shape
    assert_refused_before_allocating ["object", [2, 2], [1, 2, 3, 4], nil, {}]
    assert_refused_before_allocating ["object", [2, 2], [[1, 2], [3]], nil, {}]
  end

  def test_mask_that_does_not_fill_the_shape
    assert_refused_before_allocating ["object", [2], [1, 2], [0], {}]
  end

  def test_a_shape_that_is_not_a_shape
    assert_refused_before_allocating ["object", "x", [1], nil, {}]
    assert_refused_before_allocating ["object", [-1], [], nil, {}]
    assert_refused_before_allocating ["object", [1.5], [1], nil, {}]
  end

  def test_a_cell_holding_an_array_is_one_cell
    a = CArray.object(2)
    a[0] = [1, 2, 3]
    a[1] = []
    assert_equal [[1, 2, 3], []], Marshal.load(Marshal.dump(a)).to_a
  end

  def test_masked_object_array_comes_back
    a = CA_OBJECT([1, "a", 3]).reshape(3, 1).copy
    a[1, 0] = UNDEF
    assert_equal [[1], [UNDEF], [3]], Marshal.load(Marshal.dump(a)).to_a
  end

  def test_empty_object_array_comes_back
    assert_equal [0, 2], Marshal.load(Marshal.dump(CArray.object(0, 2))).shape
  end

end
