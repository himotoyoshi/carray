require "test/unit"
require "carray"

# CAConstString reads `buffer + start` for `end - start` bytes on the strength
# of the (start,end) pair in its storage.  Two entry points decide whether that
# pair can be trusted: the wrap door, which is where already-built offsets come
# in (the Arrow import path), and the storage itself, which used to stay
# writable behind a read-only Face.
class TestCAConstStringOffsetValidation < Test::Unit::TestCase

  def pairs (*ranges)
    pe = CArray.new(CA_FIXLEN, [ranges.size], :bytes => 16)
    ranges.each_with_index { |(s, e), i| pe[i] = [s, e].pack("q2") }
    pe
  end

  # ---- the wrap door validates ------------------------------------------

  def test_wrap_rejects_a_range_past_the_buffer
    err = assert_raise(ArgumentError) do
      CAConstString.wrap(pairs([0, 3], [0, 4096]), buffer: "abc")
    end
    assert_match(/element 1/, err.message)
    assert_match(/\[0,4096\)/, err.message)
    assert_match(/3-byte buffer/, err.message)
  end

  def test_wrap_rejects_an_inverted_range
    assert_raise(ArgumentError) { CAConstString.wrap(pairs([3, 0]), buffer: "abc") }
  end

  def test_wrap_rejects_a_negative_start
    assert_raise(ArgumentError) { CAConstString.wrap(pairs([-1, 2]), buffer: "abc") }
  end

  def test_wrap_accepts_the_exact_end_of_the_buffer
    ct = CAConstString.wrap(pairs([0, 3], [3, 3]), buffer: "abc")
    assert_equal ["abc", ""], ct.to_a
  end

  # A masked cell may hold any bytes at all -- that is the CArray mask
  # contract -- so wrap does not judge it.  No reader dereferences it: the
  # native scan skips on the mask before it touches an offset, and `.value`,
  # the explicit strip, raises from the bounds-checked decode.
  def test_wrap_exempts_masked_cells_but_no_reader_dereferences_them
    pe = pairs([0, 3], [999, 1999])
    pe.mask = 0
    pe.mask[1] = 1
    ct = CAConstString.wrap(pe, buffer: "abc")
    assert_equal ["abc", UNDEF], ct.to_a
    assert_equal [true, UNDEF], ct.include?("a").to_a
    assert_equal [3, UNDEF], ct.byte_length.to_a
    assert_equal "abc", ct.min
    assert_raise(IndexError) { ct.value.to_a }
  end

  # ---- wrap takes ownership of the offsets -------------------------------

  def test_the_storage_behind_a_column_is_read_only
    cs = CArray.const_string(%w[alpha beta gamma])
    assert_equal true, cs.read_only?
    assert_equal true, cs.parent.read_only?
  end

  def test_the_storage_cannot_be_rewritten_behind_the_face
    cs = CArray.const_string(%w[alpha beta gamma])
    assert_raise(RuntimeError) { cs.parent[2] = [1 << 40, (1 << 40) + 64].pack("q2") }
    assert_equal %w[alpha beta gamma], cs.to_a
  end

  def test_a_wrapped_offset_entity_becomes_read_only
    pe = pairs([0, 3])
    assert_equal false, pe.read_only?
    CAConstString.wrap(pe, buffer: "abc")
    assert_equal true, pe.read_only?
  end

  # ---- the ordinary surface is untouched ---------------------------------

  def test_the_builders_still_produce_readable_columns
    cs = CArray.const_string(["a", "bb", nil, "ccc"])
    assert_equal ["a", "bb", UNDEF, "ccc"], cs.to_a
    assert_equal "abbccc", cs.buffer
    assert_equal [1, 2, UNDEF, 3], cs.byte_length.to_a
    assert_equal "a", cs.min
    assert_equal "ccc", cs.max
    assert_equal ["a", "bb", "ccc"], cs.unique.to_a
    assert_equal [false, false, true, false], cs.copy.is_masked.to_a
  end

  def test_copy_and_views_of_a_wrapped_column_still_work
    ct = CAConstString.wrap(pairs([0, 1], [1, 3], [3, 6]), buffer: "abbccc")
    assert_equal %w[a bb ccc], ct.to_a
    assert_equal %w[bb ccc], ct[1..2].to_a
    assert_equal %w[a bb ccc], ct.copy.to_a
    assert_equal "abbccc", ct.copy.buffer
  end

  # `end - start` is carried as int64 now, so a record longer than 2**31 is a
  # length rather than a negative number.  Only the arithmetic is asserted
  # here; allocating such a buffer is not.
  def test_record_length_is_not_truncated_to_int32
    big = 1 << 31
    err = assert_raise(ArgumentError) { CAConstString.wrap(pairs([0, big]), buffer: "abc") }
    assert_match(/\[0,#{big}\)/, err.message)
  end

end
