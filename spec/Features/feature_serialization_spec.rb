require "carray"
require "rspec-power_assert"

describe CArray do

  example "dump_io ()" do
    begin
      a = CArray.int32(3, 3).seq!
      b = CArray.int32(3, 3)
      open("bintest", "w") { |io| a.dump_binary(io) }
      open("bintest")      { |io| b.load_binary(io) }
      is_asserted_by { a == b }

      a = CArray.int32(3, 3).seq!
      b = CArray.int32(3, 3).seq!
      open("bintest", "w") { |io| a[0..1, 0..1].dump_binary(io) }
      open("bintest")      { |io| b[0..1, 0..1].load_binary(io) }
      is_asserted_by { a == b }
    ensure
      File.unlink("bintest")
    end
  end

  example "dump_str ()" do
    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3)
    s = ""
    a.dump_binary(s)
    b.load_binary(s)
    is_asserted_by { a == b }

    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3).seq!
    s = ""
    a[0..1, 0..1].dump_binary(s)
    b[0..1, 0..1].load_binary(s)
    is_asserted_by { a == b }
  end


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
