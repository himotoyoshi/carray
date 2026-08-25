require "test/unit"
require "carray"

# A MemoryView producer is a first-class coercion operand: CArray.result_type
# derives an operand's data_type from its MV format (via ca_arg_to_data_type ->
# ca_mv_probe_data_type), and is_in accepts an MV producer as its set argument
# (routed through wrap_readonly).
#
# Ruby's MemoryView is experimental and ships no producer for tests, so this
# uses MVBorrower::Producer -- a minimal in-repo producer mock backing a 1-D
# view with an arbitrary format string.  If the peer extension isn't built,
# this file is skipped.
#
# Build the peer:
#   cd spec_ai/ext_memory_view_test && ruby extconf.rb && make

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_result_type_mv_producer: mv_borrower.bundle not built."
  warn "Build it with: (cd #{borrower_dir} && ruby extconf.rb && make)"
  return
end

class TestResultTypeMVProducer < Test::Unit::TestCase

  # Producer.new(bytes, format_or_nil, item_size)
  def prod (values, pack, format, item_size)
    MVBorrower::Producer.new(values.pack(pack), format, item_size)
  end

  def test_probe_numeric_formats
    assert_equal(:int32,    CArray.result_type(prod([1, 2, 3],   "l*", "l", 4)))
    assert_equal(:float64,  CArray.result_type(prod([1.0, 2.0],  "d*", "d", 8)))
    assert_equal(:float32,  CArray.result_type(prod([1.0],       "f*", "f", 4)))
    assert_equal(:uint8,    CArray.result_type(prod([1],         "C*", "C", 1)))
  end

  def test_probe_complex_and_fixlen
    assert_equal(:cmplx128,
                 CArray.result_type(MVBorrower::Producer.new([1.0, 2.0].pack("d*"), "Zd", 16)))
    assert_equal(:fixlen,
                 CArray.result_type(MVBorrower::Producer.new("abcdefgh", "8s", 8)))
  end

  # A producer drives promotion against a CArray self, same as a CArray operand.
  def test_result_type_promotes_against_carray_self
    assert_equal(:float64, CArray.result_type(CA_INT16([1]), prod([1.0], "d*", "d", 8)))
    assert_equal(:int64,   CArray.result_type(CA_INT64([1]), prod([1],   "C*", "C", 1)))
  end

  # Formats carray can't represent host-endian fall back to value inference
  # (CA_OBJECT), rather than raising: the probe returns -1.
  def test_opposite_endian_format_falls_back_to_object
    host_le = ([1].pack("l").unpack1("l") == 1)
    opp = host_le ? ">d" : "<d"
    assert_equal(:object, CArray.result_type(MVBorrower::Producer.new([1.0].pack("d"), opp, 8)))
  end

  # A typeless producer (format == NULL) has no intrinsic dtype; probe returns
  # -1 and result_type falls back to value inference (CA_OBJECT).
  def test_typeless_producer_falls_back_to_object
    assert_equal(:object, CArray.result_type(MVBorrower::Producer.new("\x00\x00\x00\x00", nil, 4)))
  end

  # End-to-end: is_in / intersection accept an MV producer as the set argument.
  def test_is_in_and_set_ops_accept_producer_set
    a = CA_INT32([1, 2, 3, 4, 5])
    setp = prod([2, 4], "l*", "l", 4)
    assert_equal([false, true, false, true, false], a.is_in(setp).to_a)
    assert_equal([2, 4], a.intersection(prod([4, 2, 9], "l*", "l", 4)).to_a)
  end

  # Value-correct promotion: an int self against a float producer set promotes
  # to float, so 2.5 matches instead of truncating.
  def test_is_in_producer_float_set_promotes
    af = CA_FLOAT64([1.0, 2.5, 3.0])
    setp = MVBorrower::Producer.new([2.5, 9.0].pack("d*"), "d", 8)
    assert_equal([false, true, false], af.is_in(setp).to_a)
  end
end
