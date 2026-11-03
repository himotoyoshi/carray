require "test/unit"
require "carray"

# dump_binary writes the element bytes straight into a String buffer.
# The String must not keep a code range it cached before the write, or a
# later encoding check answers from the stale cache instead of the bytes.
class TestDumpBinaryCodeRange < Test::Unit::TestCase

  def as_utf8 (s)
    s.dup.force_encoding("UTF-8")
  end

  def test_returned_string_is_checked_by_contents
    b = CA_UINT8([0xff, 0x41]).dump_binary
    assert_equal false, as_utf8(b).valid_encoding?
    assert_equal "?A", as_utf8(b).scrub("?")
  end

  def test_to_s_is_checked_by_contents
    assert_equal false, as_utf8(CA_UINT8([0xff, 0x41]).to_s).valid_encoding?
  end

  def test_given_ascii_string_is_checked_by_contents
    s = "AB".b
    assert_equal true, s.ascii_only?
    CA_UINT8([0xff, 0x41]).dump_binary(s)
    assert_equal false, s.ascii_only?
    assert_equal false, as_utf8(s).valid_encoding?
  end

  def test_given_string_of_other_length
    s = "ABCD".b
    s.ascii_only?
    CA_UINT8([0x41, 0xff]).dump_binary(s)
    assert_equal "A\xFF".b, s
    assert_equal false, s.ascii_only?
  end

  def test_view_is_checked_by_contents
    a = CA_UINT8([0x41, 0xff, 0x42])
    assert_equal false, as_utf8(a[1..2].dump_binary).valid_encoding?
  end

  def test_ascii_contents_stay_valid
    assert_equal true, as_utf8(CA_UINT8([0x41, 0x42]).dump_binary).valid_encoding?
  end

end
