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
      is_asserted_by { CArray.dump(@it) == File.binread("test.ca") }
    end

    after do
      File.unlink("test.ca")
    end

  end

  describe "object type is refused by the portable format" do

    # 3.0: the _CARRAY3 portable format never serialises CA_OBJECT
    # (arbitrary Ruby objects have no fixed-offset raw representation).
    # Object arrays persist through the Ruby-only Marshal path instead.
    example "CArray.save raises on an object array" do
      original = CArray.object(10,10) { 3.times { Time.now } }
      expect { CArray.save(original, "test.ca") }.to raise_error(ArgumentError)
    end

  end

  describe "loaded from binary format (attributes)" do

    before do
      @original = CArray.float64(4).seq
      @original.set_attr(:units, "m/s")
      @original.set_attr(:fillvalue, Float::INFINITY)
      @original.set_attr(:valid_range, [0.0, -Float::INFINITY])
      CArray.save(@original, "test.ca")
      @it = CArray.load("test.ca")
    end

    example "round-trips attributes including non-finite Floats" do
      is_asserted_by { @it == @original }
      is_asserted_by { @it.attr("units") == "m/s" }
      is_asserted_by { @it.attr("fillvalue") == Float::INFINITY }
      is_asserted_by { @it.attr("valid_range") == [0.0, -Float::INFINITY] }
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
