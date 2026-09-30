# spec_ai/test_fixlen_width.rb
#
# A fixlen cell is at least one byte wide.  `bytes: 0` and a missing
# `bytes:` are refused at every entry point; they used to give zero-width
# cells, which dropped what was written to them.  Where the data says how
# wide it is (`CA_FIXLEN(strings)`), the width is taken from it, with 1
# for all-empty data.

require "test/unit"
require "carray"

class TestFixlenWidth < Test::Unit::TestCase

  REFUSED = {
    "CArray.fixlen(3, bytes: 0)"          => -> { CArray.fixlen(3, bytes: 0) },
    "CArray.fixlen(3)"                    => -> { CArray.fixlen(3) },
    "CArray.new(:fixlen, [3])"            => -> { CArray.new(:fixlen, [3]) },
    "CArray.empty(:fixlen, [3])"          => -> { CArray.empty(:fixlen, [3]) },
    "CScalar.new(:fixlen)"                => -> { CScalar.new(:fixlen) },
    "template(:fixlen)"                   => -> { CArray.int32(3).template(:fixlen) },
    "fake(:fixlen, bytes: 0)"             => -> { CArray.int32(3).fake(:fixlen, bytes: 0) },
    "field(0, :fixlen)"                   => -> { CArray.fixlen(3, bytes: 4).field(0, :fixlen) },
    "fixlen.to_type(:fixlen)"             => -> { CArray.fixlen(3, bytes: 2).to_type(:fixlen) },
    "object.to_type(:fixlen)"             => -> { CArray.object(2) { "abc" }.to_type(:fixlen) },
    "CA_FIXLEN(data, bytes: 0)"           => -> { CA_FIXLEN(["a"], bytes: 0) },
    "CA_FIXLEN(3.5)"                      => -> { CA_FIXLEN(3.5) },
    "wrap_readonly(String, CA_FIXLEN)"    => -> { CArray.wrap_readonly("abc", CA_FIXLEN) },
  }

  def test_zero_or_missing_width_is_refused
    REFUSED.each do |label, make|
      e = assert_raise(RuntimeError, label) { make.call }
      assert_match(/bytes: of 1 or more/, e.message, label)
    end
  end

  def test_width_taken_from_the_data
    a = CA_FIXLEN(["ab", "abcd", ""])
    assert_equal 4, a.bytes
    assert_equal "abcd", a[1]
    s = CA_FIXLEN("abc")
    assert_equal 3, s.bytes
    assert_equal "abc", s[0]
  end

  def test_all_empty_data_is_one_byte_wide
    assert_equal 1, CA_FIXLEN(["", ""]).bytes
    assert_equal 1, CA_FIXLEN("").bytes
    assert_equal [1, [0]], CA_FIXLEN([]).then { |x| [x.bytes, x.shape] }
    assert_equal [1, [0]], CA_FIXLEN(nil).then { |x| [x.bytes, x.shape] }
  end

  # Iterators build empty and scratch arrays of their payload's type; for a
  # fixlen payload (a Face whose surface is fixlen) they carry its width.
  def test_iterators_over_a_fixlen_surface
    t = CArray.time(%w[2024-01-03 2024-01-01 2024-01-05 2024-01-02], unit: :D)
    mn = t.segments(lengths: [2, 2]).min
    assert_kind_of CATime, mn
    assert_equal %w[2024-01-01 2024-01-02], mn.to_a.map(&:to_s)
  end

end
