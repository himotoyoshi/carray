require "test/unit"
require "carray"

# CAStride tests using bulk-memory-view as the producer, exercising
# negative strides and arbitrary layouts that arise from BMV.wrap.
# Skipped if bulk-memory-view is not installed.

begin
  require "bulk-memory-view"
rescue LoadError
  warn "Skipping test_ca_obj_stride_bmv: bulk-memory-view not installed."
  return
end

class TestCAStrideBMV < Test::Unit::TestCase

  def setup
    @bmv = BulkMemoryView.new([4, 5], format: "d")
    @bmv.write((0...20).map(&:to_f).pack("d*"))
  end

  def test_contiguous_bmv_returns_cawrap
    ca = CArray.wrap_memory_view(@bmv)
    assert_kind_of(CAWrap, ca)
    assert_equal([4, 5], ca.shape)
    assert_equal(13.0, ca[2, 3])
  end

  def test_all_axes_reversed_returns_castride
    rev = BulkMemoryView.wrap(@bmv, strides: @bmv.strides.map(&:-@))
    ca = CArray.wrap_memory_view(rev)
    assert_kind_of(CAStride, ca)
    assert_equal([4, 5], ca.shape)
    assert_equal([-40, -8], ca.strides)
    assert_equal(19.0, ca[0, 0])   # last element of original
    assert_equal(0.0,  ca[3, 4])   # first element of original
  end

  def test_yrev_negative_axis0_stride
    yrev = BulkMemoryView.wrap(@bmv, strides: [-@bmv.strides[0], @bmv.strides[1]])
    ca = CArray.wrap_memory_view(yrev)
    assert_kind_of(CAStride, ca)
    assert_equal([-40, 8], ca.strides)
    # ca[0,*] = original row 3, ca[3,*] = original row 0
    assert_equal([15.0, 16.0, 17.0, 18.0, 19.0], (0..4).map { |x| ca[0, x] })
    assert_equal([0.0,  1.0,  2.0,  3.0,  4.0],  (0..4).map { |x| ca[3, x] })
  end

  def test_transpose_via_strides_swap
    t = BulkMemoryView.wrap(@bmv,
                            shape:   @bmv.shape.reverse,
                            strides: @bmv.strides.reverse)
    ca = CArray.wrap_memory_view(t)
    assert_kind_of(CAStride, ca)
    assert_equal([5, 4], ca.shape)
    assert_equal([8, 40], ca.strides)
    # ca[i,j] == bmv[j,i]
    assert_equal(0.0, ca[0, 0])
    assert_equal(19.0, ca[4, 3])
    assert_equal(5.0, ca[0, 1])   # bmv[1, 0]
  end

  def test_write_through_negative_stride
    yrev = BulkMemoryView.wrap(@bmv, strides: [-@bmv.strides[0], @bmv.strides[1]])
    ca = CArray.wrap_memory_view(yrev)
    ca[0, 0] = -999.0
    # ca[0, 0] corresponds to original bmv[3, 0] (last row, first col)
    contig = CArray.wrap_memory_view(@bmv)
    assert_equal(-999.0, contig[3, 0])
  end
end
