require "test/unit"
require "carray"

# Coverage for the Step 1 hygiene fixes landed in lib/carray/struct.rb
# 2026-05-21.  Each case documents the previously-buggy or surprising
# behaviour and asserts the corrected one.

class TestCAStructHygiene < Test::Unit::TestCase

  # (a) Builder must reject duplicate member names instead of silently
  # overwriting the earlier MEMBER_TABLE entry and producing a MEMBERS
  # list with a repeated name.
  def test_builder_rejects_duplicate_member_names
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { int8 :x; int8 :x }
    end
  end

  def test_builder_rejects_duplicate_across_methods
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { int8 :x; float32 :x }
    end
  end

  # (b) decode(CArray) used to alias the input CArray.  After 3.0 it
  # copies the bytes; subsequent mutation of the source must not
  # propagate into the struct.
  def test_decode_with_carray_does_not_alias
    klass  = CArray.struct(:pack => 1) { int32 :a }
    source = klass.new(42).encode      # 4-byte binary
    ca     = CArray.uint8(source.bytesize)
    ca.load_binary(source)
    s = klass.new
    s.decode(ca)
    assert_equal(42, s.a)
    # mutate the source CArray — pre-3.0 aliasing would have changed
    # s.a; post-3.0 the decode copies and s.a stays 42.
    ca[0] = 0
    assert_equal(42, s.a)
  end

  # (c) `to_s` is no longer aliased to encode (which returned raw
  # bytes).  Calling to_s must not return arbitrary binary.
  def test_to_s_is_not_binary_dump
    klass = CArray.struct(:pack => 1) { int32 :a }
    s     = klass.new(42)
    out   = s.to_s
    # to_s should be a human-readable identifier, not the raw 4-byte
    # int32 representation.  The encoded form is still available via
    # #encode, so we just check the two forms differ.
    refute_equal(s.encode, out)
  end

  # (d) `==` is unchanged but must remain selective.
  def test_equality_with_other_class
    klass = CArray.struct(:pack => 1) { int32 :a }
    refute_equal(klass.new(42), {a: 42})
    refute_equal(klass.new(42), [42])
  end

  # (e) Hash-form initializer must reject unknown keys with a clear
  # error listing them.  Pre-3.0 behaviour was NoMethodError via
  # accidental dispatch.
  def test_hash_init_rejects_unknown_keys
    klass = CArray.struct(:pack => 1) { int32 :a; int32 :b }
    err = assert_raise(ArgumentError) { klass.new(a: 1, bogus: 2) }
    assert_match(/bogus/, err.message)
  end

  # (f) CAStruct.[] must reject too many positional arguments instead
  # of silently dropping the tail (the parallel #new already rejected
  # them).
  def test_class_index_constructor_rejects_extra_args
    klass = CArray.struct(:pack => 1) { int32 :a; int32 :b }
    assert_raise(ArgumentError) { klass[1, 2, 3] }
  end

  def test_class_index_constructor_accepts_partial_args
    klass = CArray.struct(:pack => 1) { int32 :a; int32 :b }
    s = klass[1]   # explicit "only :a was provided"
    assert_equal(1, s.a)
  end

  # (h) eql? and hash work, allowing struct instances as Hash keys
  # and Set members.
  def test_eql_and_hash_as_hash_key
    klass = CArray.struct(:pack => 1) { int32 :a; int32 :b }
    a     = klass.new(1, 2)
    b     = klass.new(1, 2)
    c     = klass.new(1, 3)
    assert(a.eql?(b))
    refute(a.eql?(c))
    assert_equal(a.hash, b.hash)
    h = { a => "first" }
    assert_equal("first", h[b])  # b retrieves via eql?/hash
    refute(h.key?(c))
  end

  # (k) typed methods must raise on no-args call (catches typos /
  # forgotten member names).
  def test_typed_method_requires_at_least_one_arg
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { int32 }
    end
  end

  # (g) typo fix: error message now says "unknown" not "unkown".
  def test_decode_with_invalid_input_uses_typed_error
    klass = CArray.struct(:pack => 1) { int32 :a }
    err = assert_raise(CAStruct::DecodeError) do
      klass.new.decode(123)
    end
    assert_match(/unknown/, err.message)
    refute_match(/unkown/, err.message)
  end

  # Error class hierarchy: a single rescue CAStruct::Error catches
  # both DefinitionError and DecodeError.
  def test_error_hierarchy
    assert(CAStruct::DefinitionError < CAStruct::Error)
    assert(CAStruct::DecodeError     < CAStruct::Error)
    caught = nil
    begin
      CArray.struct { int8 :x; int8 :x }
    rescue CAStruct::Error => e
      caught = e
    end
    assert_kind_of(CAStruct::DefinitionError, caught)
  end

end
