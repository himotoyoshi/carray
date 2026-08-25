require "carray"
require "carray/arrow_tensor"
require "test/unit"
require "json"
require "stringio"
require "tmpdir"

# Arrow tensor IPC reader/writer.  Golden fixtures under
# spec_ai/fixtures/arrow_tensor/ were produced by pyarrow.ipc.write_tensor;
# manifest.json records the expected element type, shape and values.
class TestArrowTensor < Test::Unit::TestCase

  FIXDIR = File.join(__dir__, "fixtures", "arrow_tensor")

  DTYPE = {
    "float32" => :float32, "float64" => :float64,
    "int8" => :int8, "int16" => :int16, "int32" => :int32, "int64" => :int64,
    "uint8" => :uint8, "uint16" => :uint16, "uint32" => :uint32, "uint64" => :uint64,
  }

  def flat_ca (type, shape, vals)
    CArray.new(type, [vals.length]) { |i| vals[i] }.reshape(*shape)
  end

  # pyarrow-written files must load into the expected CArray.
  def test_read_golden_fixtures
    JSON.parse(File.read(File.join(FIXDIR, "manifest.json"))).each do |m|
      type = DTYPE[m["dtype"]]
      ca = CArray.load_arrow_tensor(File.join(FIXDIR, m["file"]))
      assert_equal(type,       ca.data_type,      m["file"])
      assert_equal(m["shape"], ca.shape,          m["file"])
      assert_equal(m["flat"],  ca.flatten.to_a,   m["file"])
    end
  end

  # CArray write -> our own read must round-trip exactly.
  def test_write_then_read_self
    [
      [:float32, [2, 3],    (1..6).to_a],
      [:float64, [4],       [1.5, 2.5, 3.5, 4.5]],
      [:int32,   [2, 2, 2], (1..8).to_a],
      [:uint8,   [2, 2],    [0, 255, 17, 42]],
      [:int64,   [3],       [-3, 0, 10**12]],
    ].each do |type, shape, vals|
      src = flat_ca(type, shape, vals)
      io  = StringIO.new("".b)
      CArray::ArrowTensor.write(src, io)
      io.rewind
      got = CArray::ArrowTensor.read(io)
      assert_equal(type,  got.data_type,    "#{type} #{shape.inspect}")
      assert_equal(shape, got.shape,        "#{type} #{shape.inspect}")
      assert_equal(vals,  got.flatten.to_a, "#{type} #{shape.inspect}")
    end
  end

  # A CArray we write must be readable by pyarrow as well (cross-check file
  # exists only when the reference file is regenerated; here we round-trip
  # through the file entry points).
  def test_file_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.arrow")
      src = CArray.int32(3, 4) { |i, j| i * 10 + j }
      src.save_arrow_tensor(path)
      got = CArray.load_arrow_tensor(path)
      assert_equal(src.to_a, got.to_a)
    end
  end

  # Masked arrays are rejected (Arrow tensors carry no validity concept).
  def test_masked_rejected
    ca = CArray.int32(4) { |i| i }
    ca[1] = UNDEF
    assert_raise(ArgumentError) do
      CArray::ArrowTensor.write(ca, StringIO.new("".b))
    end
  end

  # Non-numeric-tensor types are rejected.
  def test_boolean_rejected
    ca = CArray.boolean(3) { |i| i.even? }
    assert_raise(ArgumentError) do
      CArray::ArrowTensor.write(ca, StringIO.new("".b))
    end
  end
end
