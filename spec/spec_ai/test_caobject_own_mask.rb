# frozen_string_literal: true

require "test/unit"
require "carray"

# A CAObject without mask_* hooks keeps the mask written onto it -- by
# UNDEF or by mask = -- when its values are read: a fetched value says
# nothing about the mask, and only a fetcher answering UNDEF marks a cell.
class TestCAObjectOwnMask < Test::Unit::TestCase
  class Backed < CAObject
    def initialize (buf)
      @buf = buf
      super(buf.data_type, buf.shape)
    end

    private

    def fetch_addr (a)    ; a == 4 ? UNDEF : @buf[a] ; end
    def store_addr (a, v) ; @buf[a] = v ; end
    def create_mask       ; end
  end

  class BulkBacked < Backed
    private

    def copy_data (d) ; d[] = @buf ; d[4] = UNDEF ; end
  end

  def test_a_written_undef_survives_a_read
    [Backed, BulkBacked].each do |klass|
      b = klass.new(CArray.int32(6).seq!)
      b[2] = UNDEF
      assert_equal [0, 1, UNDEF, 3, UNDEF, 5], b.to_a, klass.name
      assert_equal [0, 1, UNDEF, 3, UNDEF, 5], b.to_a, "#{klass.name}: read twice"
      assert_equal [1, UNDEF, 3], b[1..3].to_a, klass.name
      assert_equal 9, b.sum.to_i, klass.name
    end
  end

  def test_a_mask_set_with_mask_assignment_survives_a_read
    [Backed, BulkBacked].each do |klass|
      b = klass.new(CArray.int32(6).seq!)
      b.mask = CA_BOOLEAN([0, 1, 0, 0, 0, 0])
      assert_equal [0, UNDEF, 2, 3, UNDEF, 5], b.to_a, klass.name
      assert_equal [false, true, false, false, true, false], b.is_masked.to_a, klass.name
    end
  end

  def test_unmask_gives_the_cell_back
    b = Backed.new(CArray.int32(6).seq!)
    b[2] = UNDEF
    b.unmask(9)
    assert_equal [0, 1, 9, 3, UNDEF, 5], b.to_a   # the fetcher still answers UNDEF at 4
  end
end
