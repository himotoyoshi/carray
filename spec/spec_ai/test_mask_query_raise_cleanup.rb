# Asking an array for its mask can call Ruby: a CAObject answers through
# its mask hooks, and a MemoryView producer builds its export in Ruby.  A
# raise there must not leave behind what was allocated before the question
# was asked -- a new array's buffers, a grid's index copy, a MemoryView
# holder and the data side's export.
#
# Measured with utils/measure_leak.rb.

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestMaskQueryRaiseCleanup < Test::Unit::TestCase

  HOOKED = <<~RUBY
    class MaskBoom < CAObject
      def initialize (*dim)
        @src = CArray.float64(*dim).seq
        super(CA_FLOAT64, dim)
        self.mask = 0
      end
      def create_mask; end
      def mask_created?; $boom == :created ? raise("boom") : true; end
      def copy_data (d); d[] = @src; end
      def fetch_addr (a); @src[a]; end
      def mask_fetch_addr (a); $boom == :fetch ? raise("boom") : 0; end
    end
    class UnmaskedBoom < CAObject
      def initialize (*dim); super(CA_FLOAT64, dim); end
      def mask_created?; $boom == :created ? raise("boom") : false; end
      private
      def fetch_index (idx); 1.0; end
    end
  RUBY

  FROZEN_RECORD_MASK = "S = CArray.struct { uint8 :b }; m = CARecord.new(S, 16); S.freeze; "

  def bytes_per_call (expr, setup, calls: 200)
    bytes = LeakMeter.bytes_per_call(expr, setup: setup, calls: calls)
    omit "measurement unavailable" if bytes.nil?
    bytes
  end

  def assert_frees (expr, setup, limit: 4096, calls: 200)
    grown = bytes_per_call(expr, setup, calls: calls)
    assert_operator grown, :<, limit,
                    "#{expr}: the C heap grew #{grown.round} bytes per call"
  end

  def test_raises
    eval(HOOKED)
    a = MaskBoom.new(4)
    $boom = :fetch
    assert_raise(RuntimeError) { a.to_type(:float32) }
    $boom = :created
    assert_raise(RuntimeError) { UnmaskedBoom.new(4, 2)[CA_INT64([1, 0]), nil] }
    $boom = nil
    s = CArray.struct { uint8 :b }
    m = CARecord.new(s, 16)
    s.freeze
    assert_raise(FrozenError) { CArray.wrap_memory_view(CArray.int8(16), mask: m) }
    assert_raise(FrozenError) { CArray.from_memory_view(CArray.int8(16), mask: m) }
  ensure
    $boom = nil
  end

  # The new array is built, and the source's mask read into it after.
  def test_new_array_from_a_mask_read_by_ruby
    assert_frees "a.to_type(:float32)",
                 HOOKED + "a = MaskBoom.new(1 << 16); $boom = :fetch"
  end

  # The grid copies its index array before it asks the parent for a mask.
  def test_grid_over_a_parent_whose_mask_query_raises
    assert_frees "b[idx, nil]",
                 HOOKED + "b = UnmaskedBoom.new(1 << 16, 2); " \
                          "idx = CArray.int64(1 << 16).seq; $boom = :created",
                 limit: 65536    # the index copy is 512 KB; the call moves a few KB without it
  end

  # The mask's export raises after the data side's has been taken.
  def test_wrap_memory_view_with_a_mask_whose_export_raises
    assert_frees "CArray.wrap_memory_view(d, mask: m)",
                 FROZEN_RECORD_MASK + "d = CArray.int8(16)",
                 limit: 64, calls: 3000
  end

  def test_from_memory_view_with_a_mask_whose_export_raises
    assert_frees "CArray.from_memory_view(d, mask: m)",
                 FROZEN_RECORD_MASK + "d = CArray.int8(16)",
                 limit: 64, calls: 3000
  end

end
