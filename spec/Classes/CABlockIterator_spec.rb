require "carray"
require "rspec-power_assert"

# CABlockIterator 3.0 (lib/carray/block_iterator.rb): a non-overlapping tile
# reduction dispatcher built on block_view decomposition.  The 2.0 surface
# (indexed CABlock access via [], pick / put, kernel_at_addr) was retired with
# its C engine; the family surface is each / reduce plus named reductions.

describe CABlockIterator do

  describe "#each" do

    before do
      @original = CArray.object(4, 4).seq!
      @it = @original.blocks(2, 2)          # 2x2 tiles, exact -> 2x2 grid
    end

    example "yields one tile per grid cell" do
      count = 0
      @it.each { |tile| count += 1 }
      is_asserted_by { count == 4 }
    end

    example "yields each tile in row-major grid order" do
      tiles = @it.each.map(&:to_a)
      is_asserted_by { tiles[0] == [[0, 1], [4, 5]] }
      is_asserted_by { tiles[1] == [[2, 3], [6, 7]] }
      is_asserted_by { tiles[2] == [[8, 9], [12, 13]] }
      is_asserted_by { tiles[3] == [[10, 11], [14, 15]] }
    end

    example "without a block returns an Enumerator" do
      is_asserted_by { @it.each.is_a?(Enumerator) }
    end

  end

  describe "named reductions" do

    before do
      @a = CArray.int32(4, 4).seq
    end

    example "mean is per-tile, shaped like the tile grid" do
      m = @a.blocks(2, 2).mean
      is_asserted_by { m.shape == [2, 2] }
      # tile (0,0) = [0,1,4,5] -> mean 2.5
      is_asserted_by { m[0, 0] == 2.5 }
    end

    example "max pools each tile" do
      is_asserted_by { @a.blocks(2, 2).max == CA_INT32([[5, 7], [13, 15]]) }
    end

  end

  describe "remainder coverage" do

    example "a partial edge tile is present-only (ceil grid)" do
      a = CArray.int32(5).seq          # tiles [0,1,2], [3,4]
      it = a.blocks(3)
      is_asserted_by { it.sum.to_a == [3, 7] }        # 0+1+2, 3+4
      is_asserted_by { it.each.to_a.last.to_a == [3, 4, UNDEF] }  # OOB masked
    end

  end

  describe "#reduce" do

    example "folds each tile with a custom block" do
      a = CArray.int32(6).seq          # tiles [0,1], [2,3], [4,5]
      out = a.blocks(2).reduce { |tile| tile.max }
      is_asserted_by { out.to_a == [1, 3, 5] }
    end

  end

end
