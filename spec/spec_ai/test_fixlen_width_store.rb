require "test/unit"
require "carray"

# Fixlen cells of one width stored into fixlen cells of another, and fixlen
# pieces of different widths joined.  The bytes are fitted cell by cell:
# padded with NUL into a wider cell, cut to a narrower one, as a String or
# an Array of Strings stored into fixlen cells is.
class TestFixlenWidthStore < Test::Unit::TestCase

  def test_store_narrow_into_wide_pads_each_cell
    o = CArray.fixlen_string(["abcdefgh"] * 2).send(:face_storage)
    o[] = CArray.fixlen_string(%w[x y]).send(:face_storage)
    assert_equal ["x" + "\0" * 7, "y" + "\0" * 7], o.to_a
  end

  def test_store_wide_into_narrow_cuts_each_cell
    o = CArray.fixlen_string(%w[ab c]).send(:face_storage)
    o[] = CArray.fixlen_string(%w[xyzw q]).send(:face_storage)
    assert_equal ["xy", "q\0"], o.to_a
  end

  def test_store_matches_the_string_rule
    a = CArray.fixlen_string(%w[ab c]).send(:face_storage)
    a[] = ["xyzw", "q"]
    b = CArray.fixlen_string(%w[ab c]).send(:face_storage)
    b[] = CArray.fixlen_string(%w[xyzw q]).send(:face_storage)
    assert_equal a.to_a, b.to_a
  end

  def test_store_into_a_view
    m = CArray.fixlen_string(%w[ab c d]).send(:face_storage)
    m[0..1] = CArray.fixlen_string(%w[xyzw q]).send(:face_storage)
    assert_equal ["xy", "q\0", "d\0"], m.to_a
  end

  def test_store_between_fixlen_string_faces
    n = CArray.fixlen_string(%w[ab c])
    n[] = CArray.fixlen_string(%w[xyzw q])
    assert_equal ["xy", "q"], n.to_a
  end

  def test_concatenate_takes_the_widest_width
    [[%w[abcdefgh], %w[a b c]], [%w[a], %w[bcd]]].each do |x, y|
      c = CArray.concatenate([CArray.fixlen_string(x), CArray.fixlen_string(y)])
      assert_kind_of CAFixlenString, c
      assert_equal x + y, c.to_a
    end
  end

  def test_concatenate_plain_fixlen_pads
    c = CArray.concatenate([CArray.fixlen_string(%w[ab]).parent,
                            CArray.fixlen_string(%w[xyz]).parent])
    assert_equal 3, c.bytes
    assert_equal ["ab\0", "xyz"], c.to_a
  end

  def test_frame_concatenate_keeps_every_string
    f = ->(k) { CAFrame.new("k" => k, "v" => CA_INT32((1..k.elements).to_a)) }
    c = CAFrame.concatenate(f.(CArray.fixlen_string(["abcdefgh"])),
                            f.(CArray.fixlen_string(%w[a b c])))
    assert_equal %w[abcdefgh a b c], c["k"].to_a
    assert_equal [1, 1, 2, 3], c["v"].to_a
  end
end
