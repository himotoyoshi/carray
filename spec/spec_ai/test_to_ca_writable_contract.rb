# frozen_string_literal: true
#
# `to_ca(writable: true)` -- the sharing half of the to_ca contract.
#
# 3.0 merged the 2.0 pair (`ca` = zero-copy, `to_ca` = copy) into one
# method: to_ca returns the receiver for a CArray and converts as cheaply
# as it can otherwise, copying only when it must.  That leaves no way to
# read, from the result alone, whether writes to it reach the source --
# and only the callee knows.  So the caller states the requirement:
#
#   to_ca                  -- "give me a CArray, doing the least work"
#   to_ca(writable: true)  -- "...and writes to it must reach me"
#
# An implementation that can only hand back a detached copy raises rather
# than returning one, so a write can never be swallowed silently.  This is
# what CArray.wrap_writable duck-types on; the 2.0 `#ca` hook is gone.
#
# Pins:
#   - CArray#to_ca honours the keyword: self, or raise when read-only
#   - copy-only implementations (lazy views, CAConstString, Array, Range,
#     ArithmeticSequence) refuse writable: true
#   - wrap_writable accepts a foreign object whose to_ca shares storage,
#     and writes through it land in the source
#   - wrap_writable refuses a copy-only source, a non-CArray to_ca result,
#     and a read-only one
#   - an object carrying only the retired `#ca` hook is no longer special

require "test/unit"
require "carray"

# to_ca hands back the wrapped array itself: storage is shared, so
# writable: true can be honoured.
class WritableToCaSource
  def initialize(ca)
    @ca = ca
  end

  def to_ca(writable: false)
    @ca
  end
end

# to_ca can only produce a detached copy, so it refuses the demand.
class CopyOnlyToCaSource
  def initialize(ca)
    @ca = ca
  end

  def to_ca(writable: false)
    if writable
      raise "CopyOnlyToCaSource#to_ca can only return a copy; " \
            "it can't satisfy `writable: true'"
    end
    @ca.copy
  end
end

# Implements to_ca but returns something that is not a CArray.
class NonCArrayToCaSource
  def to_ca(writable: false)
    [1, 2, 3]
  end
end

# to_ca predating the keyword: the ArgumentError is the honest report
# that this class does not implement writable intake.
class ZeroArityToCaSource
  def initialize(ca)
    @ca = ca
  end

  def to_ca
    @ca
  end
end

# The retired 2.0 hook, now just an ordinary object.
class LegacyCaHookSource
  def initialize(ca)
    @ca = ca
  end

  def ca
    @ca
  end
end

class TestToCaWritableContract < Test::Unit::TestCase

  # -- CArray itself ----------------------------------------------------

  def test_carray_to_ca_writable_returns_self
    a = CArray.int32(3).seq
    assert_equal true, a.to_ca(writable: true).equal?(a)
    assert_equal true, a.to_ca(writable: false).equal?(a)
    assert_equal true, a.to_ca.equal?(a)
  end

  def test_carray_to_ca_writable_on_data_view_returns_self
    a = CArray.int32(3, 4).seq
    v = a[1, nil]
    assert_equal true, v.to_ca(writable: true).equal?(v)
  end

  def test_carray_to_ca_writable_refuses_read_only
    a = CArray.int32(3).seq.freeze
    assert_equal true, a.read_only?
    assert_nothing_raised { a.to_ca }
    assert_raise(RuntimeError) { a.to_ca(writable: true) }
  end

  def test_to_ca_rejects_unknown_keyword
    a = CArray.int32(3).seq
    assert_raise(ArgumentError) { a.to_ca(sharing: true) }
  end

  # -- copy-only implementations in-tree --------------------------------

  def test_lazy_view_refuses_writable
    a = CArray.int32(3).seq
    lazy = a.lazy + 1
    assert_equal [1, 2, 3], lazy.to_ca.to_a
    assert_raise(RuntimeError) { lazy.to_ca(writable: true) }
  end

  def test_const_string_refuses_writable
    cs = CArray.const_string(%w[alpha beta])
    assert_equal %w[alpha beta], cs.to_ca.to_a
    assert_raise(RuntimeError) { cs.to_ca(writable: true) }
  end

  def test_array_range_sequence_refuse_writable
    assert_equal [1, 2], [1, 2].to_ca.to_a
    assert_raise(RuntimeError) { [1, 2].to_ca(writable: true) }
    assert_raise(RuntimeError) { (0..2).to_ca(writable: true) }
    assert_raise(RuntimeError) { (0..4).step(2).to_ca(writable: true) }
  end

  # -- wrap_writable duck-typing ----------------------------------------

  def test_wrap_writable_accepts_sharing_to_ca_and_writes_through
    base = CArray.int32(3).seq
    w = CArray.wrap_writable(WritableToCaSource.new(base))
    assert_equal true, w.equal?(base)
    w[0] = 42
    assert_equal [42, 1, 2], base.to_a
  end

  def test_wrap_writable_adapts_data_type_and_still_writes_through
    base = CArray.int32(3).seq
    w = CArray.wrap_writable(WritableToCaSource.new(base), :float64)
    assert_equal CA_FLOAT64, w.data_type
    w[1] = 7.0
    assert_equal [0, 7, 2], base.to_a
  end

  def test_wrap_writable_refuses_copy_only_source
    base = CArray.int32(3).seq
    assert_raise(RuntimeError) do
      CArray.wrap_writable(CopyOnlyToCaSource.new(base))
    end
  end

  def test_wrap_readonly_still_accepts_copy_only_source
    base = CArray.int32(3).seq
    r = CArray.wrap_readonly(CopyOnlyToCaSource.new(base))
    assert_equal [0, 1, 2], r.to_a
    assert_equal false, r.equal?(base)
  end

  def test_wrap_writable_refuses_non_carray_to_ca_result
    assert_raise(TypeError) do
      CArray.wrap_writable(NonCArrayToCaSource.new)
    end
  end

  def test_wrap_writable_refuses_read_only_to_ca_result
    base = CArray.int32(3).seq.freeze
    assert_raise(RuntimeError) do
      CArray.wrap_writable(WritableToCaSource.new(base))
    end
  end

  def test_wrap_writable_reports_to_ca_without_the_keyword
    base = CArray.int32(3).seq
    assert_raise(ArgumentError) do
      CArray.wrap_writable(ZeroArityToCaSource.new(base))
    end
  end

  # -- the retired `#ca` hook -------------------------------------------

  def test_legacy_ca_hook_is_no_longer_duck_typed
    base = CArray.int32(3).seq
    assert_raise(RuntimeError) do
      CArray.wrap_writable(LegacyCaHookSource.new(base))
    end
    # wrap_readonly treats it as an ordinary object: a 1-element
    # :object CScalar holding the source itself, not its array.
    r = CArray.wrap_readonly(LegacyCaHookSource.new(base))
    assert_equal CA_OBJECT, r.data_type
    assert_equal true, r[0].is_a?(LegacyCaHookSource)
  end
end
