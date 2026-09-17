# sort_copy must answer for exactly what sort answers for.
#
# It is documented as the eager counterpart of sort, but it refused
# everything its own per-fiber fast path could not take: that path covers
# unmasked CA_INT8..CA_FLOAT64, and fixlen and masked input had an escape
# to sort + copy while object and boolean had none.  So an object or
# boolean array sorted through `sort` and raised through `sort_copy`, and
# complex reported its refusal in two different ways depending on which of
# the pair was asked.
#
# The escape now covers everything outside the fast path, so the pair
# agrees: where sort answers, sort_copy answers with the same values in an
# owned array; where sort refuses, sort_copy refuses the same way.

require 'test/unit'
require 'carray'

class TestSortCopyParity < Test::Unit::TestCase

  def sorts (a)
    [a.sort.to_a, a.sort_copy.to_a]
  end

  def test_object_sorts_both_ways
    a = CA_OBJECT([3, 1, 2])
    want, got = sorts(a)
    assert_equal [1, 2, 3], want
    assert_equal want, got
    assert_equal true, a.sort_copy.entity?
  end

  def test_object_along_an_axis
    a = CA_OBJECT([[3, 1], [2, 4]])
    assert_equal a.sort(axis: 1).to_a, a.sort_copy(axis: 1).to_a
    assert_equal [[1, 3], [2, 4]], a.sort_copy(axis: 1).to_a
  end

  def test_boolean_sorts_both_ways
    a = CArray.boolean(4) { |i| i.odd? }
    want, got = sorts(a)
    assert_equal [false, false, true, true], want
    assert_equal want, got
  end

  def test_a_string_face_keeps_its_class
    a = CArray.string(%w[pear apple fig kiwi])
    assert_equal ["apple", "fig", "kiwi", "pear"], a.sort_copy.to_a
    assert_kind_of CAString, a.sort_copy
  end

  def test_masked_object_clusters_like_sort
    a = CA_OBJECT([3, 1, 2])
    a[0] = UNDEF
    assert_equal [1, 2, UNDEF], a.sort_copy.to_a
    assert_equal [UNDEF, 1, 2], a.sort_copy(masked_position: :first).to_a
  end

  def test_the_numeric_fast_path_is_untouched
    assert_equal [1, 2, 3], CA_INT32([3, 1, 2]).sort_copy.to_a
    assert_equal [[1.0, 3.0], [2.0, 4.0]],
                 CA_FLOAT64([[3.0, 1.0], [2.0, 4.0]]).sort_copy(axis: 1).to_a
    m = CA_INT32([3, 1, 2])
    m[0] = UNDEF
    assert_equal [1, 2, UNDEF], m.sort_copy.to_a
  end

  def test_fixlen_still_goes_through_sort
    a = CArray.new(CA_FIXLEN, [3], bytes: 4)
    %w[c a b].each_with_index { |s, i| a[i] = s }
    assert_equal a.sort.to_a, a.sort_copy.to_a
  end

  # Complex has no ordering in either member; what matters is that the two
  # refuse alike rather than one of them inventing its own message.
  def test_complex_is_refused_by_both
    a = CA_CMPLX128([Complex(2, 0), Complex(1, 0)])
    got = [:sort, :sort_copy].map do |m|
      begin
        a.send(m)
        nil
      rescue CArray::DataTypeError => e
        e.message
      end
    end
    assert_not_nil got[0]
    assert_equal got[0], got[1]
  end

  def test_kind_is_still_checked
    assert_raise(ArgumentError) { CA_OBJECT([1]).sort_copy(kind: :bogus) }
    assert_equal [1, 2, 3], CA_OBJECT([3, 1, 2]).sort_copy(kind: :stable).to_a
  end

end
