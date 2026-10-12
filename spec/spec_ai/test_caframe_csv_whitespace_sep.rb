require "test/unit"
require "stringio"
require "carray"

# A space or a tab as the separator.  Each one separates fields as written:
# two in a row hold an empty field, and strip: skips the other blanks around
# a field but never the separator itself.  strip: reads in Ruby, so these
# also hold the Ruby tokenizer to what the C reader does.
class TestCAFrameCSVWhitespaceSep < Test::Unit::TestCase

  def cols(text, **opts)
    df = CAFrame.from_csv(StringIO.new(text), **opts)
    df.column_names.map { |n| df[n].to_a }
  end

  def test_space_separator_keeps_an_empty_field
    assert_equal [["1"], [UNDEF], ["3"]], cols("a b c\n1  3\n", sep: " ")
    assert_equal [["1"], [UNDEF], ["3"]], cols("a b c\n1  3\n", sep: " ", strip: true)
  end

  def test_space_separator_with_a_leading_empty_field
    assert_equal [[UNDEF, "x"], ["2", "y"]], cols("a b\n 2\nx y\n", sep: " ", strip: true)
  end

  def test_space_separator_keeps_a_quoted_cr
    assert_equal [["\r"], ["y"]], cols("a b\n\"\r\" y\n", sep: " ", strip: true)
  end

  def test_space_separator_round_trip_in_another_encoding
    a = CA_OBJECT(["", "x"]); a[0] = UNDEF
    df = CAFrame.new("a" => a, "b" => CA_OBJECT(%w[2 y]))
    text = df.to_csv(sep: " ").encode("CP932")
    back = CAFrame.from_csv(StringIO.new(text), sep: " ")
    assert_equal [[UNDEF, "x"], ["2", "y"]], back.column_names.map { |n| back[n].to_a.map { |v| v == UNDEF ? v : v.encode("UTF-8") } }
  end

  def test_strip_does_not_eat_a_tab_separator
    assert_equal [["1"], [UNDEF], ["3"]], cols("a\tb\tc\n1\t\t\"3\"\n", sep: "\t", strip: true)
    assert_equal [["x"], ["y"]], cols("a\tb\n\"x\"\ty\n", sep: "\t", strip: true)
  end

  def test_strip_still_skips_spaces_with_a_tab_separator
    assert_equal [["x"], ["y"]], cols("a\tb\n  \"x\"  \t  y \n", sep: "\t", strip: true)
  end

  def test_strip_still_skips_tabs_with_a_space_separator
    assert_equal [["x"], ["y"]], cols("a b\n\t\"x\"\t y\t\n", sep: " ", strip: true)
  end

end
