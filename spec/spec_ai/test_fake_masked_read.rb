# frozen_string_literal: true
#
# A converting view (CAFake) reads only the cells that are not masked: the
# value under a mask is not defined, and converting it (NaN to an integer)
# would raise.  Every way of reading answers as attach does.

require "test/unit"
require "carray"

class TestFakeMaskedRead < Test::Unit::TestCase
  def setup
    @b = CA_DOUBLE([1.5, Float::NAN, 3.5, 2.0]).mask_invalid
    @w = @b.fake(:int32)
  end

  def test_every_read_skips_the_masked_cell
    assert_equal [1, UNDEF, 3, 2], @w.copy.to_a
    assert_equal UNDEF, @w[1]
    assert_equal 1, @w[0]
    assert_equal 6, @w.sum
    assert_equal [UNDEF, 3], @w[1..2].copy.to_a
    assert_equal [2, UNDEF, 1], @w[CA_INT64([3, 1, 0])].to_a
    assert_equal [[1, 3], [UNDEF, 2]], @b.reshape(2, 2).fake(:int32).transpose.copy.to_a
    assert_equal @b.as_type(:int32).copy.to_a, @w.copy.to_a
  end

  def test_a_boolean_view_of_bytes_skips_the_masked_byte
    u = CA_UINT8([1, 7, 0])
    u[1] = UNDEF
    assert_equal [true, UNDEF, false], u.fake(:boolean).copy.to_a
  end

  def test_writes_and_unmasked_reads_are_unchanged
    @w[0] = 9
    assert_equal [9.0, UNDEF, 3.5, 2.0], @b.to_a
    assert_equal [1, 2], CA_DOUBLE([1.5, 2.5]).fake(:int32).copy.to_a
  end
end
