# spec_ai/test_to_type_raise_cleanup.rb
#
# `to_type` attaches its source while it casts.  When the cast raises (an
# int32 cell outside 0/1 cast to boolean), the source is detached before
# the raise propagates, not left attached for good.

require "test/unit"
require "carray"

class TestToTypeRaiseCleanup < Test::Unit::TestCase

  # A column of a matrix: a view that attaches into a buffer of its own.
  def column
    CArray.int32(4, 4) { 2 }[nil, 1]
  end

  def test_view_detached_after_failed_cast
    v = column
    assert_raise(RuntimeError) { v.to_type(CA_BOOLEAN) }
    assert_equal false, v.attached?
  end

  def test_view_reads_current_parent_after_failed_cast
    big = CArray.int32(4, 4) { 2 }
    v = big[nil, 1]
    assert_raise(RuntimeError) { v.to_type(CA_BOOLEAN) }
    big[nil, 1] = 1
    assert_equal [true] * 4, v.to_type(CA_BOOLEAN).to_a
  end

  def test_masked_view_detached_after_failed_cast
    big = CArray.int32(4, 4) { 2 }
    big[0, 1] = UNDEF
    v = big[nil, 1]
    assert_raise(RuntimeError) { v.to_type(CA_BOOLEAN) }
    assert_equal false, v.attached?
  end
end
