# CArray.promote_list(list, data_type: nil) — single primitive that
# "normalises" a list so every element shares a uniform representation
# (= same Face class, or same primitive data_type).  Used by the compose
# family (bind / merge / composite / combine / concat / mosaic) as the
# input-conditioning step before CArray.stack or __ragged_paste.

require 'test/unit'
require 'carray'
require 'carray/time'
require 'carray/const_string'

class TestPromoteList < Test::Unit::TestCase

  # ---------------- auto: homogeneous Face ----------------

  def test_face_homogeneous_passes_through
    a = CATime.new(3, unit: :ns)
    b = CATime.new(3, unit: :ns)
    out = CArray.promote_list([a, b])
    # Pass-through: same Face instances returned (= no wrap_readonly).
    assert_equal 2, out.size
    assert_same a, out[0]
    assert_same b, out[1]
  end

  def test_face_state_mismatch_raises
    a = CATime.new(3, unit: :ns)
    b = CATime.new(3, unit: :s)
    err = assert_raise(ArgumentError) { CArray.promote_list([a, b]) }
    assert_match(/state mismatch/, err.message)
    assert_match(/CATime/, err.message)
  end

  def test_face_not_portable_raises
    t1 = CArray.const_string(["aa", "bb"])
    t2 = CArray.const_string(["cc", "dd"])
    err = assert_raise(ArgumentError) { CArray.promote_list([t1, t2]) }
    assert_match(/not portable/, err.message)
    assert_match(/CAConstString/, err.message)
  end

  # ---------------- auto: primitive ----------------

  def test_primitive_same_dtype_returns_homogeneous
    a = CArray.int32(3) { 0 }
    b = CArray.int32(3) { 1 }
    out = CArray.promote_list([a, b])
    assert_equal 2, out.size
    assert_equal :int32, out[0].data_type
    assert_equal :int32, out[1].data_type
  end

  def test_primitive_different_dtype_promotes
    a = CArray.int32(3)   { 0 }
    b = CArray.float64(3) { 1.0 }
    out = CArray.promote_list([a, b])
    assert_equal :float64, out[0].data_type
    assert_equal :float64, out[1].data_type
  end

  # ---------------- auto: mixed reject ----------------

  def test_mixed_face_and_primitive_raises
    a = CATime.new(3, unit: :ns)
    b = CArray.int64(3) { 0 }
    err = assert_raise(ArgumentError) { CArray.promote_list([a, b]) }
    assert_match(/cannot mix Face and non-Face/, err.message)
  end

  def test_heterogeneous_face_classes_raises
    a = CATime.new(3, unit: :s)
    b = CATimedelta.new(3, unit: :s)
    # The error comes from the "Face state mismatch / heterogeneous Face"
    # rejection; the specific path depends on class-identity detection.
    err = assert_raise(ArgumentError) { CArray.promote_list([a, b]) }
    # Either "mix" or "heterogeneous Face" wording is acceptable.
    assert_match(/heterogeneous|mix Face/, err.message)
  end

  # ---------------- explicit data_type: primitive ----------------

  def test_explicit_data_type_primitive_coerces
    a = CArray.int32(3)   { 0 }
    b = CArray.float64(3) { 1.0 }
    out = CArray.promote_list([a, b], data_type: :int64)
    assert_equal :int64, out[0].data_type
    assert_equal :int64, out[1].data_type
  end

  def test_explicit_data_type_primitive_rejects_face
    a = CATime.new(3, unit: :ns)
    err = assert_raise(ArgumentError) {
      CArray.promote_list([a], data_type: :int64)
    }
    assert_match(/cannot be applied to a list containing Face/, err.message)
  end

  # ---------------- explicit data_type: Class rejected ----------------

  def test_explicit_data_type_class_rejected
    a = CArray.int32(3) { 0 }
    err = assert_raise(ArgumentError) {
      CArray.promote_list([a], data_type: CATime)
    }
    assert_match(/must be a primitive Symbol/, err.message)
  end

  def test_explicit_data_type_module_rejected
    a = CArray.int32(3) { 0 }
    # Module is also Class-shaped; same reject path.
    err = assert_raise(ArgumentError) {
      CArray.promote_list([a], data_type: Comparable)
    }
    assert_match(/must be a primitive Symbol/, err.message)
  end

  # ---------------- empty / errors ----------------

  def test_empty_list_raises
    err = assert_raise(ArgumentError) { CArray.promote_list([]) }
    assert_match(/must not be empty/, err.message)
  end

  # ---------------- single element ----------------

  def test_single_face_element_passes_through
    a = CATime.new(3, unit: :ns)
    out = CArray.promote_list([a])
    assert_equal 1, out.size
    assert_same a, out[0]
  end

  def test_single_primitive_element_passes_through
    a = CArray.int32(3) { 0 }
    out = CArray.promote_list([a])
    assert_equal 1, out.size
    # Single-element primitive: type promotion is a no-op, so wrap_readonly
    # on a same-dtype source may return self.  Either same instance or a
    # data_type-matching coerce is acceptable.
    assert_equal :int32, out[0].data_type
  end

  # ---------------- integration: compose family round-trip ----------------

  def test_merge_uses_promote_list_internally
    a = CATime.new(3, unit: :ns)
    b = CATime.new(3, unit: :ns)
    # CArray.stack calls promote_list then CArray.stack; the Face is
    # preserved through the chain.
    s = CArray.stack([a, b])
    assert_kind_of CATime, s
    assert_equal :ns, s.unit.base
  end

  def test_merge_with_primitive_explicit_dtype
    a = CArray.int32(3) { 0 }
    b = CArray.float64(3) { 1.0 }
    s = CArray.stack([a, b], data_type: :float64)
    assert_equal "float64", s.data_type_name
  end

  def test_concat_with_homogeneous_primitive
    a = CArray.int32(3) { |i| i }
    b = CArray.int32(2) { |i| 100 + i }
    out = CArray.concatenate([a, b])
    assert_kind_of CArray, out
    assert_equal [5], out.shape
    assert_equal :int32, out.data_type
  end
end
