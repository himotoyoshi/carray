# is_in / intersection / difference / union take an Array of Strings against
# a fixlen array.
#
# The set built from a bare Array went through to_type(:fixlen) with no
# bytes:, which builds it at width 0 -- every element becomes "" -- and the
# C guard then refused the set for not matching self.  So the plainest
# spelling, a.is_in(["be"]), raised CArray::DataTypeError on every fixlen
# array, CAFixlenString included.
#
# The set is now built at self's cell width, which is the same rule a
# scalar operand of a comparison follows: a String standing in for a cell
# is padded out to the cell's width.
#
# A set given as a CArray still has to be that width already.  When it is
# not, the refusal now says which width was wanted, rather than reporting a
# data type mismatch between two fixlen arrays.

require 'test/unit'
require 'carray'

class TestIsInFixlen < Test::Unit::TestCase

  def setup
    @raw = CArray.new(CA_FIXLEN, [3], bytes: 5)
    %w[alpha be alpha].each_with_index { |w, i| @raw[i] = w }
    @face = CArray.fixlen_string(%w[alpha be alpha])
  end

  def test_is_in_an_array_of_strings
    assert_equal [false, true, false], @raw.is_in(["be"]).to_a
    assert_equal [true, true, true],   @raw.is_in(%w[alpha be]).to_a
    assert_equal [false, false, false], @raw.is_in(["nope"]).to_a
  end

  def test_a_short_string_and_its_padded_spelling_agree
    assert_equal @raw.is_in(["be"]).to_a, @raw.is_in(["be\0\0\0"]).to_a
  end

  def test_the_face_too
    assert_equal [false, true, false], @face.is_in(["be"]).to_a
  end

  def test_the_set_operations
    assert_equal ["be\0\0\0"], @raw.intersection(["be"]).to_a
    assert_equal ["alpha"],    @raw.difference(["be"]).to_a
    assert_equal ["alpha", "be\0\0\0", "zulu\0"], @raw.union(["zulu"]).to_a
  end

  def test_the_set_operations_re_lift_a_face
    r = @face.intersection(["be"])
    assert_kind_of CAFixlenString, r
    assert_equal ["be"], r.to_a
  end

  def test_a_range_set
    a = CArray.new(CA_FIXLEN, [3], bytes: 1)
    %w[a b c].each_with_index { |w, i| a[i] = w }
    assert_equal [true, true, false], a.is_in("a".."b").to_a
  end

  def test_a_carray_set_of_the_right_width_still_works
    v = CArray.new(CA_FIXLEN, [1], bytes: 5)
    v[0] = "be"
    assert_equal [false, true, false], @raw.is_in(v).to_a
  end

  # The remaining refusal is a real one -- two fixlen arrays of different
  # widths hold values of different lengths -- and now says so.
  def test_a_width_mismatch_names_the_width
    v = CArray.new(CA_FIXLEN, [1], bytes: 3)
    v[0] = "be"
    e = assert_raise(CArray::DataTypeError) { @raw.is_in(v) }
    assert_match(/5 bytes wide/, e.message)
    assert_match(/not 3/, e.message)
    e2 = assert_raise(CArray::DataTypeError) { @raw.intersection(v) }
    assert_match(/5 bytes wide/, e2.message)
  end

  # A numeric set never reaches the guard: result_type refuses to promote
  # fixlen and int32 to a common type first, which is the right place.
  def test_a_genuine_data_type_mismatch_is_refused_at_the_promotion
    e = assert_raise(RuntimeError) { @raw.is_in(CA_INT32([1])) }
    assert_match(/int32/,  e.message)
    assert_match(/fixlen/, e.message)
  end

  def test_other_data_types_are_untouched
    assert_equal [false, true, true],   CA_INT32([1, 2, 3]).is_in([2, 3]).to_a
    assert_equal [false, false, false], CA_INT32([1, 2, 3]).is_in([2.5]).to_a
    assert_equal [false, true],         CA_OBJECT(%w[a b]).is_in(["b"]).to_a
    assert_equal [false, true],         CArray.string(%w[a b]).is_in(["b"]).to_a
    assert_equal [false, true],         CArray.const_string(%w[a b]).is_in(["b"]).to_a
    assert_equal [2, 3],                CA_INT32([1, 2, 3]).intersection([2, 3]).to_a
  end

end
