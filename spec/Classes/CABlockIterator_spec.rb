require "carray"
require "rspec-power_assert"

describe CABlockIterator do

  describe "each method" do

    before do
      @original = CArray.object(4,4).seq!
      @it = @original.blocks(0..1, 0..1)
    end

    example "should call 4-times its block" do
      count = 0
      @it.each do |blk|
        count += 1
      end
      is_asserted_by { count == 4 }
    end

    example "should have the block parameter of 2x2 CABlock object" do
      @it.each do |blk|
        is_asserted_by { blk.class == CABlock }
        is_asserted_by { blk.data_type == CA_OBJECT }
        is_asserted_by { blk.dim == [2,2] }
      end
    end

  end

  describe "reference method []" do

    before do
      @original = CArray.object(4,4).seq!
      @it = @original.blocks(0..1, 0..1)
    end

    example "should return a 2x2 CABlock object" do
      blk = @it[0]
      is_asserted_by { blk.class == CABlock }
      is_asserted_by { blk.data_type == CA_OBJECT }
      is_asserted_by { blk == CA_OBJECT([[0,1],[4,5]]) }
      blk = @it[1,0]
      is_asserted_by { blk.class == CABlock }
      is_asserted_by { blk.data_type == CA_OBJECT }
      is_asserted_by { blk == CA_OBJECT([[8,9],[12,13]]) }
    end

    example "should return a 2x2 CABlock object" do
      is_asserted_by { @it[0] == @it.kernel_at_addr(0, @it.reference) }
      is_asserted_by { @it[1,0] == @it.kernel_at_index([1,0], @it.reference) }
    end

  end

  describe "store method []=" do

    before do
      @original = CArray.object(4,4).seq!
      @it = @original.blocks(0..1, 0..1)
    end

    example "should return a 2x2 CABlock object" do
      @it[0] = 1
      @it[1,0] = 2
      is_asserted_by { @it.reference == CA_OBJECT( [ [ 1, 1, 2, 3 ],
                                               [ 1, 1, 6, 7 ],
                                               [ 2, 2, 10, 11 ],
                                               [ 2, 2, 14, 15 ] ] ) }
    end

  end

  describe "pick method" do

    before do
      @original = CArray.object(4,4).seq!
      @it = @original.blocks(0..1, 0..1)
    end

    example "should return a 2x2 CABlock object" do
      blk = @it.pick(0)
      is_asserted_by { blk.class == CArray }
      is_asserted_by { blk.data_type == CA_OBJECT }
      is_asserted_by { blk == CA_OBJECT([[0,2],[8,10]]) }
      blk = @it.pick(1,0)
      is_asserted_by { blk.class == CArray }
      is_asserted_by { blk.data_type == CA_OBJECT }
      is_asserted_by { blk == CA_OBJECT([[4,6],[12,14]]) }
    end

  end

  describe "put method" do

    before do
      @original = CArray.object(4,4).seq!
      @it = @original.blocks(0..1, 0..1)
    end

    example "should store value via 2x2 CBlock object" do
      @it.put(0,1)
      @it.put(0,1,2)
      is_asserted_by { @it.pick(0) == CA_OBJECT([[1,1],[1,1]]) }
      is_asserted_by { @it.pick(0,1) == CA_OBJECT([[2,2],[2,2]]) }
      is_asserted_by { @it.reference == CA_OBJECT([[ 1, 2, 1, 2 ],
                                             [ 4, 5, 6, 7 ],
                                             [ 1, 2, 1, 2 ],
                                             [ 12, 13, 14, 15 ]]) }
    end

  end

end
