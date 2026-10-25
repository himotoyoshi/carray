# spec_ai/test_partial_transfer_without_xfer_stride.rb
#
# A view type that leaves out the xfer_stride slot (allowed: the dispatcher
# has a default) still answers a partial read or write by the cells asked
# for.  Over a root that computes its cells -- a CAObject with per-cell
# hooks -- reading one row or writing six cells calls the hooks for those
# cells, not for the whole root.  The fixture CAIterOffsetNoXfer is such a
# type: it adds an offset on read and takes it off on write.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_source_kind", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_source_kind"
rescue LoadError
  warn "Skipping test_partial_transfer_without_xfer_stride: iter_source_kind not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestPartialTransferWithoutXferStride < Test::Unit::TestCase

  class Cold < CAObject
    attr_reader :calls
    def initialize (back)
      @back = back
      @calls = Hash.new(0)
      super(back.data_type, back.shape)
    end
    def create_mask; end
    def fetch_addr (a) = (@calls[:fetch] += 1; @back[a])
    def store_addr (a, v) = (@calls[:store] += 1; @back[a] = v)
  end

  def setup
    @back = CArray.int32(4, 6).seq!
    @cold = Cold.new(@back)
    @view = CAIterOffsetNoXfer.wrap(@cold, 100)
  end

  def test_reading_a_row_reads_its_cells
    assert_equal (100...106).to_a, @view[0, nil].to_a
    assert_equal 6, @cold.calls[:fetch]
  end

  def test_reading_a_column_through_a_transpose
    assert_equal [101, 107, 113, 119], @view.transpose[1, nil].to_a
    assert_equal 4, @cold.calls[:fetch]
  end

  def test_writing_a_row_through_an_index_array_writes_its_cells
    @view[CA_INT64([2]), nil] = CA_INT32([[109, 109, 109, 109, 109, 109]])
    assert_equal 6, @cold.calls[:store]
    assert_operator @cold.calls[:fetch], :<=, 6
    expect = CArray.int32(4, 6).seq!
    expect[2, nil] = 9
    assert_equal expect.to_a, @back.to_a
  end

  def test_the_whole_view_still_reads_and_writes
    assert_equal (CArray.int32(4, 6).seq! + 100).to_a, @view.to_a
    @view[] = 100
    assert_equal [0] * 24, @back.to_a.flatten
  end
end
