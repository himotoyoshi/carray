$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# Hand-written kernels that read or write outside their buffers, or let
# the garbage collector take values they still hold.

class TestProjectKeepsObjectValues < Test::Unit::TestCase

  # The gathered cells of an object array are VALUEs that only the result
  # keeps alive once the lazy source is detached.
  def with_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  def test_project_from_lazy_object_source
    x = CA_OBJECT(["a", "b"]).lazy + "z"
    got = with_stress { x.project(CA_INT64([1, 0])) }
    assert_equal ["bz", "az"], got.to_a
  end

  def test_project_with_fill_from_lazy_object_source
    x = CA_OBJECT(["a", "b"]).lazy + "z"
    got = with_stress { x.project(CA_INT64([1, 5, -1]), "lo", "hi") }
    assert_equal ["bz", "hi", "lo"], got.to_a
  end

  def test_take_along_axis_with_masked_index_from_lazy_object_source
    x = CA_OBJECT(["a", "b", "c"]).lazy + "z"
    idx = CA_INT64([2, 0, 1])
    idx[1] = UNDEF
    got = with_stress { x.take_along_axis(idx, axis: 0) }
    assert_equal ["cz", UNDEF, "bz"], got.to_a
  end

end

class TestBincountNdUnsignedLabels < Test::Unit::TestCase

  # A uint64 label above INT64_MAX is past the last bin, like any other
  # label past it: it lands in the overflow cell of its own fiber.
  def test_largest_uint64_label_counts_in_its_own_overflow_cell
    labels = CA_UINT64([[[2**64 - 1], [1]], [[0], [1]]])
    assert_equal [[0, 1, 0, 1], [1, 1, 0, 0]],
                 labels.bincount_nd(lengths: [3]).full_counts.to_a
  end

  def test_largest_uint64_label_in_the_second_fiber
    labels = CA_UINT64([[[0], [1]], [[2**64 - 1], [1]]])
    assert_equal [[1, 1, 0, 0], [0, 1, 0, 1]],
                 labels.bincount_nd(lengths: [3]).full_counts.to_a
  end

  def test_uint64_label_just_above_int64_max
    labels = CA_UINT64([[[2**63 + 5], [1]], [[0], [1]]])
    assert_equal [[0, 1, 0, 1], [1, 1, 0, 0]],
                 labels.bincount_nd(lengths: [3]).full_counts.to_a
  end

  def test_agrees_with_int64_labels_past_the_last_bin
    big = CA_UINT64([[[2**63], [2]], [[1], [0]]])
    ref = CA_INT64([[[100], [2]], [[1], [0]]])
    assert_equal ref.bincount_nd(lengths: [3]).full_counts.to_a,
                 big.bincount_nd(lengths: [3]).full_counts.to_a
  end

end

class TestElemIndexArrayLength < Test::Unit::TestCase

  def setup
    @a = CArray.int32(2, 3, 4).seq
  end

  def test_short_index_array_raises
    assert_raise(IndexError) { @a.elem_fetch([1]) }
    assert_raise(IndexError) { @a.elem_store([1, 2], -7) }
    assert_raise(IndexError) { @a.elem_mask([0]) }
  end

  def test_long_index_array_raises
    assert_raise(IndexError) { @a.elem_fetch([0, 0, 0, 99]) }
  end

  # A short array that once held more entries must not read the old slots.
  def test_shrunk_index_array_raises
    i = [1, 2, 0]
    i.pop
    i.pop
    assert_raise(IndexError) { @a.elem_fetch(i) }
  end

  def test_swap_and_copy_check_both_indices_before_writing
    before = @a.to_a
    assert_raise(IndexError) { @a.elem_swap([0, 0, 0], [1]) }
    assert_raise(IndexError) { @a.elem_copy([0, 0, 0], [1, 2]) }
    assert_equal before, @a.to_a
  end

  def test_matching_length_still_works
    assert_equal 23, @a.elem_fetch([1, 2, 3])
  end

  def test_view_agrees_with_entity
    v = @a.transpose
    assert_raise(IndexError) { v.elem_fetch([1]) }
    assert_raise(IndexError) { v.elem_fetch([0, 0, 0, 0]) }
  end

end
