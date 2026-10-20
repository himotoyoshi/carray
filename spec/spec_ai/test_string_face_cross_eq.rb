require "test/unit"
require "carray"

# Two string arrays of different kinds or widths are compared by their
# strings.  CAString.eq(CAFixlenString) compared a string with the padded
# bytes, true only where a string filled its cell, and two widths of
# CAFixlenString compared unequal throughout.
class TestStringFaceCrossEq < Test::Unit::TestCase

  def test_across_kinds
    s = CArray.string(%w[ab apple x])
    f = CArray.fixlen_string(%w[ab apple x])
    c = CArray.const_string(%w[ab apple x])
    [[s, f], [f, s], [s, c], [c, f]].each do |a, b|
      assert_equal [true, true, true], a.eq(b).to_a, "#{a.class} eq #{b.class}"
    end
    assert_equal [false, false, false], f.ne(s).to_a
  end

  def test_across_widths
    w2 = CArray.fixlen_string(%w[ab cd])
    w8 = CArray.fixlen_string(%w[ab cd], bytes: 8)
    assert_equal [true, true], w2.eq(w8).to_a
    assert_equal [true, true], w8.eq(w2).to_a
    assert_equal [false, false], w2.lt(w8).to_a
  end

  def test_a_masked_cell_stays_masked
    s = CArray.string(["ab", nil])
    assert_equal [true, UNDEF], s.eq(CArray.fixlen_string(%w[ab cd])).to_a
  end

end
