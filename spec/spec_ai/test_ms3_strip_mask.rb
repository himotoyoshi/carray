# MS.3: strip_mask(fill) -- the return-form "mask-dissociated copy".
#
# PROPOSAL_MASK_SET_FAMILY.md §2.2: strip_mask is the canonical name
# (1 intent) replacing unmask_copy (= 2 intents: "unmask" + "copy").
# Fill is mandatory (arity 1, no default) per the "all arguments
# mandatory" regularity.
#
# Pinned:
#   - returns new CArray (self unchanged)
#   - returned array has no mask (= structure dissociated)
#   - masked input cells receive fill value in output
#   - data_type + shape preserved
#   - arity 1 strict (no-arg / 2-arg both raise ArgumentError)

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS3StripMask < Test::Unit::TestCase

  def test_returns_new_array
    a = CArray.float64(5).seq
    a[2] = UNDEF
    c = a.strip_mask(-999.0)
    refute_equal(a.object_id, c.object_id)
  end

  def test_self_unchanged
    a = CArray.float64(5).seq
    a[2] = UNDEF
    a.strip_mask(-999.0)
    assert(a.has_mask?, "self should retain its mask")
    assert_equal(true, a.is_masked[2])
  end

  def test_output_has_no_mask
    a = CArray.float64(5).seq
    a[2] = UNDEF
    c = a.strip_mask(-999.0)
    refute(c.has_mask?, "strip_mask output should have no mask structure")
  end

  def test_fill_value_at_masked_positions
    a = CArray.float64(6).seq
    a[1] = UNDEF
    a[4] = UNDEF
    c = a.strip_mask(-999.0)
    assert_equal([0.0, -999.0, 2.0, 3.0, -999.0, 5.0], c.to_a)
  end

  def test_no_mask_input_returns_equivalent
    a = CArray.float64(5).seq
    c = a.strip_mask(-999.0)
    refute(c.has_mask?)
    assert_equal(a.to_a, c.to_a)
  end

  def test_data_type_and_shape_preserved
    a = CArray.int32(3, 4).seq
    a[1, 2] = UNDEF
    c = a.strip_mask(-7)
    assert_equal(a.data_type, c.data_type)
    assert_equal(a.shape, c.shape)
    assert_equal(-7, c[1, 2])
  end

  # ---- arity strict ----------------------------------------------------

  def test_no_arg_raises
    a = CArray.float64(3).seq
    assert_raise(ArgumentError) { a.strip_mask }
  end

  def test_two_args_raises
    a = CArray.float64(3).seq
    assert_raise(ArgumentError) { a.strip_mask(-1.0, -2.0) }
  end

  def test_arity_is_optional
    # strip_mask gained a `method:` keyword and an optional positional fill
    # (the constant path still requires a value, guarded at call time; see
    # test_no_arg_raises).  Arity flips 1 -> -1.
    a = CArray.float64(3).seq
    assert_equal(-1, a.method(:strip_mask).arity)
  end

  # ---- multiple data_types -------------------------------------------------

  def test_int_dtypes_coverage
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64].each do |t|
      a = CArray.send(t, 4).seq
      a[1] = UNDEF
      c = a.strip_mask(99)
      assert_equal(99, c[1], "data_type #{t} fill failed")
      refute(c.has_mask?, "data_type #{t} should produce no mask")
    end
  end

  def test_float_dtypes_coverage
    [:float32, :float64].each do |t|
      a = CArray.send(t, 4).seq
      a[2] = UNDEF
      c = a.strip_mask(-1.5)
      refute(c.has_mask?)
      assert_in_delta(-1.5, c[2], 1e-6)
    end
  end
end
