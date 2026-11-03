require "test/unit"
require "carray"

# A fixlen string array holds the encoding of its text.
class TestFixlenStringEncoding < Test::Unit::TestCase

  SJIS = "あ".encode("Shift_JIS")

  def test_round_trip_through_const_string
    s = CArray.const_string(["あ", "b"])
    back = s.to_fixlen_string.to_const_string
    assert_equal ["あ", "b"], back.to_a
    assert_equal Encoding::UTF_8, back.encoding
  end

  def test_cells_read_in_the_encoding
    f = CArray.fixlen_string(["あ", "b"])
    assert_equal Encoding::UTF_8, f.encoding
    assert_equal ["あ", "b"], f.to_a
  end

  def test_another_encoding_is_kept
    c = CArray.const_string([SJIS], encoding: Encoding::Shift_JIS)
    f = c.to_fixlen_string
    assert_equal Encoding::Shift_JIS, f.encoding
    assert_equal Encoding::Shift_JIS, f.to_const_string.encoding
    assert_equal [SJIS], f.to_a
  end

  def test_views_and_copies_keep_it
    f = CArray.const_string([SJIS, "b"], encoding: Encoding::Shift_JIS).to_fixlen_string
    [f[0..0], f.flip(0), f.copy, f.dup, f.sort, f.unique].each do |x|
      assert_equal Encoding::Shift_JIS, x.encoding, x.class.to_s
    end
    assert_equal Encoding::Shift_JIS, CArray.stack([f, f]).encoding
  end

  def test_strings_that_disagree_have_no_encoding
    assert_equal Encoding::BINARY, CArray.fixlen_string([SJIS, "あ"]).encoding
  end

  def test_ascii_strings_are_utf8
    assert_equal Encoding::UTF_8, CArray.fixlen_string(["a"]).encoding
  end

  def test_wrap_claims_no_encoding_unless_told
    raw = CArray.fixlen_string(["あ"]).parent
    assert_equal Encoding::BINARY, CAFixlenString.wrap(raw).encoding
    assert_equal Encoding::UTF_8, CAFixlenString.wrap(raw, encoding: "UTF-8").encoding
  end

  def test_a_binary_array_comes_back_as_a_binary_column
    raw = CArray.fixlen_string(["あ"]).parent
    assert_equal Encoding::BINARY, CAFixlenString.wrap(raw).to_const_string.encoding
  end

  def test_two_text_encodings_do_not_stack
    a = CArray.fixlen_string(["あ"])
    b = CArray.fixlen_string([SJIS])
    assert_raise(ArgumentError) { CArray.stack([a, b]) }
    assert_equal ["あ"], CArray.stack([a, CAFixlenString.wrap(a.parent)])[0, nil].to_a
  end

  def test_a_string_query_still_finds_the_cell
    f = CArray.fixlen_string(["あ", "b"])
    assert_equal [true, false], f.eq("あ").to_a
    assert_equal 0, f.search("あ")
  end

end
