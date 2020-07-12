require "carray"
require "rspec-power_assert"

describe CArray do

  describe "loaded from binary format (int32 type)" do

    before do
      @original = CArray.int32(10,10) { 10 }
      @original[5,5] = UNDEF
      CArray.save(@original, "test.ca")
      @it = CArray.load("test.ca")
    end

    example "should equal to original" do
      is_asserted_by { @it == @original }
      is_asserted_by { @it.has_mask? == true }
    end

    example "should dump string of same contents with file from which it was loaded" do 
      is_asserted_by { CArray.dump(@it) == File.read("test.ca") }
    end

    after do
      File.unlink("test.ca")
    end

  end

  describe "loaded from binary format (object type)" do

    before do
      @original = CArray.object(10,10) { 3.times { Time.now } }
      @original[5,5] = UNDEF
      CArray.save(@original, "test.ca")
      @it = CArray.load("test.ca")
    end

    example "should equal to original" do
      is_asserted_by { @it == @original }
      is_asserted_by { @it.has_mask? == true }
    end

    after do
      File.unlink("test.ca")
    end

  end

  describe "loaded by marshal (int32 type)" do
    
    before do
      @original = CArray.int32(10,10) { 10 }
      @original[5,5] = UNDEF
      open("test.ca", "w") { |io| Marshal.dump(@original, io) }
      @it = open("test.ca") { |io| Marshal.load(io) }
    end

    example "should equal to original" do
      is_asserted_by { @it == @original }
      is_asserted_by { @it.has_mask? == true }
    end

    after do
      File.unlink("test.ca")
    end

  end

  describe "loaded by marshal (object type)" do
    
    before do
      @original = CArray.object(10,10) { 3.times { Time.now } }
      @original[5,5] = UNDEF
      open("test.ca", "w") { |io| Marshal.dump(@original, io) }
      @it = open("test.ca") { |io| Marshal.load(io) }
    end

    example "should equal to original" do
      is_asserted_by { @it == @original }
      is_asserted_by { @it.has_mask? == true }
    end

    after do
      File.unlink("test.ca")
    end

  end

end
