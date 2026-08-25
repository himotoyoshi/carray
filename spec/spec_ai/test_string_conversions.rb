# PROPOSAL_STRING_FACE_TRIO.md P.4 — inter-trio conversion API.
#
# to_string / to_fixlen_string / to_const_string follow the to_ca-family
# organizing principle (§4.0): zero-copy wrap when the storage already matches
# the target, materialise otherwise.  Mask and shape are carried.
#
# Regression sweep is `rake spec_ai`.

require "test/unit"
require "carray"

class TestStringConversions < Test::Unit::TestCase

  # ---- to_string (-> CAString, object storage) ---------------------------

  def test_to_string_from_const_materializes
    c = CArray.const_string(["a", "bb", "c"])
    s = c.to_string
    assert_kind_of CAString, s
    assert_equal ["a", "bb", "c"], s.to_a
  end

  # Non-Face sources reach a Face through the builder, not an instance to_*
  # (which is String-Face only, see the gate tests below).
  def test_string_builder_from_object_wraps_zero_copy
    o = CArray.object(2); o[0] = "x"; o[1] = "y"
    s = CArray.string(o)
    assert_kind_of CAString, s
    assert_same o, s.parent            # zero-copy: object storage wrapped
  end

  def test_to_string_on_castring_is_self
    s = CArray.string(["p", "q"])
    assert_same s, s.to_string
  end

  def test_to_string_carries_mask
    c = CArray.const_string(["a", nil, "c"])
    s = c.to_string
    assert_equal [false, true, false], s.is_masked.to_a
    assert_equal UNDEF, s[1]
  end

  # ---- to_fixlen_string (-> CAFixlenString, CA_FIXLEN storage) -----------

  def test_to_fixlen_string_materializes_with_width
    s = CArray.string(["p", "qq"])
    f = s.to_fixlen_string(bytes: 3)
    assert_kind_of CAFixlenString, f
    assert_equal 3, f.bytes                    # storage padded to width 3
    assert_equal ["p", "qq"], f.to_a           # fetch strips padding
  end

  def test_to_fixlen_string_auto_width
    f = CArray.string(["a", "bbb"]).to_fixlen_string
    assert_equal 3, f.bytes            # max bytesize
  end

  def test_fixlen_builder_from_raw_fixlen_wraps_zero_copy
    fx = CArray.new(CA_FIXLEN, [2], :bytes => 3)
    fx[0] = "ab"; fx[1] = "cd"
    f = CArray.fixlen_string(fx)
    assert_kind_of CAFixlenString, f
    assert_same fx, f.parent           # zero-copy: raw fixlen storage wrapped
  end

  def test_to_fixlen_string_on_cafixlenstring_is_self
    f = CArray.fixlen_string(["ab", "cd"], bytes: 3)
    assert_same f, f.to_fixlen_string
    assert_same f, f.to_fixlen_string(bytes: 3)
  end

  def test_to_fixlen_string_truncate_error_default
    s = CArray.string(["toolong"])
    assert_raise(ArgumentError) { s.to_fixlen_string(bytes: 3) }
  end

  def test_to_fixlen_string_truncate_silent
    s = CArray.string(["toolong"])
    f = s.to_fixlen_string(bytes: 3, truncate: :silent)
    assert_equal "too", f[0]
  end

  def test_to_fixlen_string_carries_mask
    c = CArray.const_string(["a", nil, "c"])
    f = c.to_fixlen_string(bytes: 2)
    assert_equal [false, true, false], f.is_masked.to_a
  end

  # ---- to_const_string (-> CAConstString) --------------------------------
  # Materialises from any non-const storage (the packed varlen buffer cannot
  # alias arbitrary storage); self (zero-copy) when self is already a
  # CAConstString of the same encoding -- the same wrap-when-matching rule as
  # to_string / to_fixlen_string.

  def test_to_const_string_materializes
    s = CArray.string(["p", "q"])
    c = s.to_const_string
    assert_kind_of CAConstString, c
    assert_equal ["p", "q"], c.to_a
  end

  def test_to_const_string_carries_mask
    s = CArray.string(["a", nil, "c"])
    c = s.to_const_string
    assert_equal [false, true, false], c.is_masked.to_a
  end

  def test_to_const_string_on_caconststring_is_self
    c = CArray.const_string(["p", "q", "p"])
    assert_same c, c.to_const_string                       # matching encoding -> self
    assert_same c, c.to_const_string(encoding: Encoding::UTF_8)
  end

  def test_to_const_string_encoding_mismatch_materializes
    c = CArray.const_string(["p", "q"])                    # UTF-8
    r = c.to_const_string(encoding: Encoding::ASCII_8BIT)
    assert_not_same c, r
    assert_equal Encoding::ASCII_8BIT, r.encoding
  end

  # ---- shape preservation (N-D) ------------------------------------------

  def test_to_fixlen_string_preserves_ndim
    nd = CArray.string(6) { |i| i.to_s }.reshape(2, 3)
    f  = nd.to_fixlen_string
    assert_equal [2, 3], f.shape
    assert_equal "4", f[1, 1]
  end

  def test_to_string_preserves_ndim
    nd = CArray.fixlen_string(["ab", "cd", "ef", "gh"], bytes: 2).reshape(2, 2)
    s  = nd.to_string
    assert_equal [2, 2], s.shape
  end

  # ---- round trip --------------------------------------------------------

  def test_round_trip_string_fixlen_string
    s = CArray.string(["ab", "cd"])
    back = s.to_fixlen_string(bytes: 2).to_string
    assert_equal ["ab", "cd"], back.to_a
  end

  # ---- old vocabulary retired (3.0 breaking) -----------------------------

  def test_old_names_removed
    assert_raise(NoMethodError) { CArray.text(["a"]) }
    assert_equal false, CArray.const_string(["a"]).respond_to?(:to_text)
    assert_equal false, CArray.const_string(["a"]).respond_to?(:to_object)
  end

  # ---- to_* are String-Face only; construction goes through the builders --

  def test_to_conversions_are_string_face_only
    n = CArray.int32(3) { |i| i }
    [:to_string, :to_fixlen_string, :to_const_string].each do |m|
      assert_equal false, n.respond_to?(m), "numeric array should not carry ##{m}"
    end
    ct = CArray.const_string(["a"])
    [:to_string, :to_fixlen_string, :to_const_string].each do |m|
      assert_equal true, ct.respond_to?(m), "String Face should carry ##{m}"
    end
  end

  def test_builders_from_raw_fixlen_strip_padding
    fx = CArray.new(CA_FIXLEN, [3], :bytes => 4)
    fx[0] = "ab"; fx[1] = "cde"; fx[2] = "f"
    assert_equal ["ab", "cde", "f"], CArray.string(fx).to_a
    assert_equal ["ab", "cde", "f"], CArray.const_string(fx).to_a
    assert_equal ["ab", "cde", "f"], CArray.fixlen_string(fx).to_a
  end

  def test_builders_from_face_convert
    s = CArray.string(["alpha", "bb", "alpha"])
    c = CArray.const_string(s)
    assert_kind_of CAConstString, c
    assert_equal ["alpha", "bb", "alpha"], c.to_a
  end

  def test_string_builders_reject_numeric
    n = CArray.int32(3) { |i| i }
    assert_raise(CArray::DataTypeError) { CArray.string(n) }
    assert_raise(CArray::DataTypeError) { CArray.fixlen_string(n) }
    assert_raise(CArray::DataTypeError) { CArray.const_string(n) }
  end

  # Regression: ct.to_fixlen_string (no bytes) once wrapped the int64 offset
  # storage as an 8-byte fixlen, returning byte garbage. It must read the
  # string surface.
  def test_const_to_fixlen_string_reads_surface_not_offsets
    ct = CArray.const_string(["alpha", "bb", "c"])
    f  = ct.to_fixlen_string
    assert_kind_of CAFixlenString, f
    assert_equal ["alpha", "bb", "c"], f.to_a
  end

end
