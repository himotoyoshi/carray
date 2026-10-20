require "test/unit"
require "carray"

# A bytes: below 1 was made 1 without a word.  A width given is a width
# asked for, so one no cell can have is refused; the default still gives
# all-empty strings the narrowest cell.
class TestFixlenStringBytesGiven < Test::Unit::TestCase

  def test_refused
    assert_raise(ArgumentError) { CArray.fixlen_string(["a"], bytes: 0) }
    assert_raise(ArgumentError) { CArray.fixlen_string(["a"], bytes: -1) }
    assert_raise(ArgumentError) { CArray.string(["a"]).to_fixlen_string(bytes: 0) }
  end

  def test_the_default_width
    assert_equal 1, CArray.fixlen_string(["", ""]).bytes
    assert_equal 3, CArray.fixlen_string(["ab"], bytes: 3).bytes
  end

end
