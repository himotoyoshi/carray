require 'test/unit'
require 'carray'

# An UNDEF that a CAObject's copy_data writes masks the cell, as an UNDEF
# that its fetcher answers does, whether or not the object had a mask
# before: reading in bulk and reading cell by cell give the same answers,
# in either order.
class TestCAObjectUndefFromCopyData < Test::Unit::TestCase

  class Backed < CAObject
    def initialize (buf)
      @buf = buf
      super(buf.data_type, buf.shape)
    end
    def create_mask ; end
    def fetch_addr (a)    = (a == 2 ? UNDEF : @buf[a])
    def copy_data (d)
      d[] = @buf
      d[2] = UNDEF
    end
  end

  # copy_data stores a masked array whole.
  class Linked < CAObject
    def initialize (src)
      @src = src
      super(src.data_type, src.shape)
    end
    def create_mask ; end
    def fetch_addr (a)    = @src[a]
    def copy_data (d)     = d[] = @src
  end

  def backed   = Backed.new(CArray.int32(5).seq(1))
  def linked
    s = CArray.int32(5).seq(1)
    s[2] = UNDEF
    Linked.new(s)
  end

  EXPECTED = [1, 2, UNDEF, 4, 5]

  BULK = {
    "to_a"         => ->(o) { o.to_a },
    "copy"         => ->(o) { o.copy.to_a },
    "sum"          => ->(o) { o.sum },
    "count_masked" => ->(o) { o.to_a; o.count_masked },
    "sort"         => ->(o) { o.sort.to_a },
    "block"        => ->(o) { o[1..3].to_a },
  }
  ANSWER = {
    "to_a" => EXPECTED, "copy" => EXPECTED, "sum" => 12.0,
    "count_masked" => 1, "sort" => [1, 2, 4, 5, UNDEF], "block" => [2, UNDEF, 4],
  }

  def test_bulk_reads_first
    { "backed" => -> { backed }, "linked" => -> { linked } }.each do |kind, make|
      BULK.each do |name, read|
        assert_equal ANSWER[name], read.call(make.call), "#{kind} #{name}"
      end
    end
  end

  def test_bulk_reads_after_a_cell_read
    { "backed" => -> { backed }, "linked" => -> { linked } }.each do |kind, make|
      BULK.each do |name, read|
        o = make.call
        assert_equal UNDEF, o[2]
        assert_equal ANSWER[name], read.call(o), "#{kind} #{name}"
      end
    end
  end

  def test_cell_reads_after_a_bulk_read
    o = backed
    o.to_a
    assert_equal UNDEF, o[2]
    assert_equal 2, o[1]
    e = []
    o.each { |x| e << x }
    assert_equal EXPECTED, e
  end
end
