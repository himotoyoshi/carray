require "test/unit"
require "carray"

# A view with no cells moves nothing.  The per-cell walks behind the region
# transfers visit their first cell before they test the counts, so an empty
# request used to touch one cell: a write of one element into a zero-byte
# caller buffer over an entity, and a fetch of an index that does not exist
# from a root that cannot lend its memory.
#
# The root below answers from a plain CArray and records every request, so
# an empty view over it must leave the log empty.

class TestEmptyViewTransfer < Test::Unit::TestCase

  class Recorder < CAObject
    attr_reader :log
    def initialize(back)
      @back = back
      @log = []
      super(back.data_type, back.shape)
    end
    private
    def fetch_addr(a)
      @log << [:fetch, a]
      @back[a]
    end
    def store_addr(a, v)
      @log << [:store, a]
      @back[a] = v
    end
  end

  SHAPES = [[0, 6], [4, 0], [1, 0], [0, 0]]

  def views(r)
    n0, n1 = r.shape
    {
      "transpose"        => r.transpose,
      "block of transpose" => r.transpose[nil, nil],
      "grid on axis 1"   => r[nil, CArray.int64(0)],
      "select_axis on 0" => r[CArray.boolean(n0) { 1 }, nil],
      "select_axis on 1" => r[nil, CArray.boolean(n1) { 1 }],
      "shift"            => r.shift(1, 0),
      "window"           => r.window(-1..n0, 0..n1 - 1),
      "tile"             => r.tile(2, 1),
      "roll"             => r.roll(1, 0),
      "stack"            => CArray.stack([r, r]),
      "meld"             => CArray.meld([r, r]),
    }
  end

  def test_an_empty_view_over_a_cold_root_asks_it_for_nothing
    SHAPES.each do |shape|
      root = Recorder.new(CArray.float64(*shape))
      views(root).each do |name, v|
        next unless v.elements.zero?
        assert_equal(v.shape, v.copy.shape, "#{shape} #{name}: copy")
        assert_equal(0.0, v.sum, "#{shape} #{name}: sum")
        unless v.read_only?
          v[] = 1
          v.add!(1)
        end
        assert_equal([], root.log, "#{shape} #{name}")
      end
    end
  end

  def test_an_empty_view_over_an_entity_copies_and_writes
    SHAPES.each do |shape|
      e = CArray.float64(*shape)
      views(e).each do |name, v|
        assert_equal(v.shape, v.copy.shape, "#{shape} #{name}")
        v.add!(1) unless v.read_only?
      end
    end
  end

  def test_select_axis_keeps_a_zero_length_axis
    e = CArray.float64(4, 0)
    v = e[CArray.boolean(4) { |i| i.even? }, nil]
    assert_equal([2, 0], v.shape)
    assert_equal([2, 0], v.copy.shape)
  end

  def test_a_lazy_operation_with_a_scalar_on_an_empty_array
    e = CArray.float64(0, 6)
    assert_equal([0, 6], (e.lazy + 1).copy.shape)
    assert_equal([0, 6], (1 - e.lazy).copy.shape)
    assert_equal([0, 6], (e.lazy > 0).copy.shape)
    assert_equal(CA_BOOLEAN, (0 < e.lazy).copy.data_type)
    assert_equal([0], (CArray.float64(0).lazy * 2).copy.shape)
  end

end
