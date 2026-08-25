# PROPOSAL_STRING_FACE_TRIO.md P.5 — StringOperationMixin.
#
# String operations live on the three String Faces (not on CArray), with a
# tiered dispatch: L1 generic per-cell Ruby (here), overridden by a Face's
# C-native byte ops where present (L3).  Output by return category:
# String -> CAString, Integer -> :int, Boolean -> :boolean.
#
# Regression sweep is `rake spec_ai`.

require "test/unit"
require "carray"

class TestStringOperations < Test::Unit::TestCase

  FACES = %i[const_string fixlen_string string].freeze

  def each_face (values)
    FACES.each { |k| yield k, CArray.send(k, values) }
  end

  # ---- §0 main goal: numeric CArrays carry no string operations ----------

  def test_numeric_has_no_string_ops
    a = CArray.int32(3)
    %i[upcase downcase strip gsub start_with? str_len to_i in?].each do |m|
      assert_equal false, a.respond_to?(m), "numeric CArray should not answer #{m}"
    end
  end

  # ---- transforms -> CAString (Option alpha), across all three Faces -----

  def test_upcase_returns_castring
    each_face(["Ab", "cD"]) do |kind, a|
      out = a.upcase
      assert_kind_of CAString, out, "#{kind}.upcase"
      assert_equal ["AB", "CD"], out.to_a
    end
  end

  def test_transform_family
    a = CArray.string(["  Hi ", "foo"])
    assert_equal ["Hi", "foo"], a.strip.to_a
    assert_equal ["  hi ", "foo"], a.downcase.to_a
    assert_equal ["  Hi ", "fXX"], a.gsub("o", "X").to_a   # gsub replaces all
  end

  # ---- predicates -> :boolean --------------------------------------------

  def test_predicates_return_boolean
    each_face(["apple", "apricot", "banana"]) do |kind, a|
      out = a.start_with?("ap")
      assert_equal :boolean, out.data_type, "#{kind}.start_with?"
      assert_equal [true, true, false], out.to_a
    end
  end

  def test_include_and_match
    a = CArray.string(["foobar", "baz"])
    assert_equal [true, false], a.include?("oo").to_a
    assert_equal [true, false], a.match?(/o+/).to_a
  end

  # ---- length -> :int ----------------------------------------------------

  def test_str_len_returns_int
    # All three Faces report the logical length: fixlen strips its NUL padding
    # on fetch, so str_len sees "a", not "a\0\0".
    each_face(["a", "bbb", "cc"]) do |kind, a|
      out = a.str_len
      assert_equal :int32, out.data_type, "#{kind}.str_len"
      assert_equal [1, 3, 2], out.to_a, kind.to_s
    end
  end

  # ---- numeric parse -----------------------------------------------------

  def test_to_i_to_f
    assert_equal [12, 0, 34], CArray.string(["12", "x", "34"]).to_i.to_a
    assert_in_delta 3.14, CArray.string(["3.14"]).to_f[0], 1e-9
  end

  # ---- mask carried through operations -----------------------------------

  def test_mask_carried
    a = CArray.string(["a", nil, "c"])
    assert_equal [false, true, false], a.upcase.is_masked.to_a
    assert_equal [false, true, false], a.str_len.is_masked.to_a
  end

  # ---- in-place (Mutable) on mutable Faces only --------------------------

  def test_in_place_on_mutable
    s = CArray.string(["a", "b"])
    s.upcase!
    assert_equal ["A", "B"], s.to_a
    f = CArray.fixlen_string(["a", "b"], bytes: 2)
    f.upcase!
    assert_equal ["A", "B"], f.to_a
  end

  def test_readonly_has_no_bang
    c = CArray.const_string(["a"])
    assert_equal false, c.respond_to?(:upcase!)
    assert_equal false, c.respond_to?(:gsub!)
  end

  # ---- L3: CAConstString C-native overrides the L1 generic ---------------

  def test_const_string_native_override
    c = CArray.const_string(["ab", "cd"])
    assert_equal CAConstString, c.method(:start_with?).owner   # C-native, not L1
    assert_equal [true, false], c.start_with?("a").to_a
  end

  def test_castring_uses_l1_generic
    s = CArray.string(["ab", "cd"])
    assert_equal CArray::StringOperationMixin, s.method(:start_with?).owner
  end

  # ---- CArray.format -> CAString -----------------------------------------

  def test_format_returns_castring
    a = CArray.int32(3) { |i| i + 1 }
    b = CArray.string(["x", "y", "z"])
    out = CArray.format("%s#%02d", b, a)
    assert_kind_of CAString, out
    assert_equal ["x#01", "y#02", "z#03"], out.to_a
  end

  def test_format_broadcasts_non_carray
    b = CArray.string(["x", "y"])
    assert_equal ["x=42", "y=42"], CArray.format("%s=%d", b, 42).to_a
  end

  def test_format_shape_mismatch_raises
    a = CArray.int32(3)
    assert_raise(ArgumentError) { CArray.format("%d%d", a, CArray.int32(2)) }
  end

  def test_format_requires_a_carray
    assert_raise(ArgumentError) { CArray.format("%d", 5) }
  end

  # ---- in?: set membership, marks ALL matching cells -------------

  def test_in_membership
    c = CArray.const_string(["x", "y", "z", "y"])
    assert_equal [false, true, false, true], c.in?("y").to_a
    assert_equal [true, true, false, true], c.in?("x", "y").to_a
  end

end
