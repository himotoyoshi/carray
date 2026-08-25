require "test/unit"
require "carray"

# Phase A tests for CAStride: a generic strided virtual array.
# Constructed indirectly via CArray.wrap_memory_view on a strided
# producer (here, CArray's own CABlock exporter).  The BMV-driven
# scenarios (negative strides etc.) live in a separate file that
# requires bulk-memory-view as an optional dependency.

class TestCAStride < Test::Unit::TestCase

  def test_class_registered
    assert(defined?(CAStride))
    assert_equal(CAView, CAStride.superclass)
    assert(defined?(CA_OBJ_STRIDE))
    assert_kind_of(Integer, CA_OBJ_STRIDE)
  end

  def test_wrap_strided_cablock_returns_castride
    src = CArray.float64(4, 5).seq
    block = src[nil, 2]   # column slice -- strided CABlock
    rewrap = CArray.wrap_memory_view(block)
    assert_kind_of(CAStride, rewrap)
    assert_equal([4], rewrap.shape)
    assert_equal([40], rewrap.strides)
    assert_equal(0, rewrap.byte_offset)
  end

  def test_castride_reads_match_source
    src = CArray.float64(4, 5).seq
    block = src[nil, 2]
    rewrap = CArray.wrap_memory_view(block)
    assert_equal(block.to_a, rewrap.to_a)
  end

  def test_castride_writes_propagate_to_source
    src = CArray.float64(4, 5).seq
    block = src[nil, 2]
    rewrap = CArray.wrap_memory_view(block)
    rewrap[1] = -999.0
    assert_equal(-999.0, src[1, 2])
    assert_equal(-999.0, block[1])
  end

  def test_castride_2d
    src = CArray.float64(5, 6).seq
    sub = src[1..3, 2..4]   # 3x3 strided sub-block (both axes)
    rewrap = CArray.wrap_memory_view(sub)
    assert_kind_of(CAStride, rewrap)
    assert_equal([3, 3], rewrap.shape)
    assert_equal(sub.to_a, rewrap.to_a)
  end

  def test_castride_attach_materialises
    # The two-mode behavior: ptr is NULL until attached.  Inside an
    # attach! scope, ptr is a contiguous gather buffer; on detach it
    # is freed and modifications are scattered back to the parent.
    src = CArray.float64(4, 5).seq
    rewrap = CArray.wrap_memory_view(src[nil, 2])
    assert_false(rewrap.attached?)
    inside_state = nil
    rewrap.attach! do
      inside_state = rewrap.attached?
      assert_equal([2.0, 7.0, 12.0, 17.0], rewrap.to_a)
      rewrap[2] = -42.0
    end
    assert_true(inside_state)
    assert_false(rewrap.attached?)
    # After attach! exit, the write should be scattered back to src.
    assert_equal(-42.0, src[2, 2])
  end

  def test_castride_attribute_readers
    src = CArray.float64(4, 5).seq
    rewrap = CArray.wrap_memory_view(src[nil, 2])
    assert_kind_of(Array, rewrap.strides)
    assert_equal(1, rewrap.strides.length)
    assert_kind_of(Integer, rewrap.byte_offset)
  end

  # --- CArray#as_strided (low-level direct constructor) -----------------

  def test_as_strided_yrev
    src = CArray.float64(4, 5).seq
    v = src.as_strided(shape: [4, 5], strides: [-40, 8], offset: 120)
    assert_kind_of(CAStride, v)
    assert_equal([4, 5], v.shape)
    assert_equal([-40, 8], v.strides)
    assert_equal(120, v.byte_offset)
    assert_equal(src.to_a.reverse, v.to_a)
  end

  def test_as_strided_transpose
    src = CArray.float64(4, 5).seq
    t = src.as_strided(shape: [5, 4], strides: [8, 40], offset: 0)
    assert_equal(src.transpose.to_a, t.to_a)
  end

  def test_as_strided_write_through
    src = CArray.float64(4, 5).seq
    v = src.as_strided(shape: [4, 5], strides: [-40, 8], offset: 120)
    v[0, 0] = 999.0
    assert_equal(999.0, src[3, 0])
  end

  def test_as_strided_attach_scatter
    src = CArray.float64(4, 5).seq
    v = src.as_strided(shape: [4, 5], strides: [-40, 8], offset: 120)
    v.attach! do |buf|
      buf[0, 0] = 777.0
    end
    assert_equal(777.0, src[3, 0])
  end

  def test_as_strided_missing_kwargs_raises
    src = CArray.float64(4, 5).seq
    assert_raise(ArgumentError) { src.as_strided }
    assert_raise(ArgumentError) { src.as_strided(shape: [4, 5]) }
    assert_raise(ArgumentError) { src.as_strided(strides: [8, 40]) }
  end

  def test_as_strided_length_mismatch_raises
    src = CArray.float64(4, 5).seq
    assert_raise(ArgumentError) do
      src.as_strided(shape: [4, 5], strides: [8])
    end
  end
end
