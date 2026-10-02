# frozen_string_literal: true
#
# Places where a Face was refused for a reason that was not its own: a
# CAString in a multi-parent construction, a gap fill that failed from inside
# linear_fetch, and the masking methods that return a new array, which a
# read-only Face could not take because its copy is read-only too.

require "test/unit"
require "carray"
require "carray/categorical"

class TestFaceRefusalGaps < Test::Unit::TestCase

  def strings
    CArray.const_string(%w[ab dd cd]).to_string
  end

  # ---- a CAString stacks ----------------------------------------------------

  def test_string_face_in_multi_parent_constructions
    u = strings
    r = CArray.stack([u, u])
    assert_kind_of CAString, r
    assert_equal [%w[ab dd cd], %w[ab dd cd]], r.to_a
    assert_kind_of CAString, CArray.concatenate([u, u])
    assert_equal %w[ab dd cd ab dd cd], CArray.meld(u, u).to_a
    assert_equal true, CAString.face_state_portable?
  end

  def test_const_string_still_refuses_multi_parent_constructions
    s = CArray.const_string(%w[ab dd cd])
    assert_raise(ArgumentError) { CArray.stack([s, s]) }
  end

  # ---- :linear gap fill asks whether the Face interpolates ------------------

  def test_linear_gap_fill_refuses_a_face_without_its_own_linear_fetch
    [strings, strings.to_const_string.to_fixlen_string,
     CArray.const_string(%w[ab dd cd])].each do |a|
      m = a.is_a?(CAConstString) ? CArray.const_string(["ab", nil, "cd"]) : a.copy
      m[1] = UNDEF unless a.is_a?(CAConstString)
      e = assert_raise(ArgumentError) { m.strip_mask(method: :linear) }
      assert_match(/does not interpolate/, e.message)
      assert_equal %w[ab ab cd], m.strip_mask(method: :forward).to_a
    end
  end

  def test_linear_gap_fill_still_interpolates_time
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-05], unit: :D)
    t[1] = UNDEF
    r = t.strip_mask(method: :linear)
    assert_kind_of CATime, r
    assert_equal %w[2024-01-01 2024-01-03 2024-01-05], r.to_a.map(&:to_s)
  end

  # ---- the masking methods that return a new array, on a read-only Face -----

  def test_mask_return_forms_on_a_const_string
    s = CArray.const_string(%w[ab dd cd])
    r = s.mask_eq("dd")
    assert_kind_of CAConstString, r
    assert_equal ["ab", UNDEF, "cd"], r.to_a
    assert_equal %w[ab dd cd], s.to_a
    assert_equal [UNDEF, "dd", "cd"], s.mask_where(CA_BOOLEAN([1, 0, 0])).to_a
    assert_equal ["ab", UNDEF, UNDEF], s.mask_where(:gt, "ab").to_a
    assert_equal [UNDEF, UNDEF, "cd"], s.mask_where(0..1).to_a
  end

  def test_mask_return_forms_on_a_categorical
    c = CA_OBJECT(%w[ab dd cd]).categorize
    r = c.mask_eq("dd")
    assert_kind_of CACategorical, r
    assert_equal ["ab", UNDEF, "cd"], r.to_a
    assert_equal %w[ab dd cd], c.to_a
    assert_equal [UNDEF, "dd", "cd"], c.mask_where(CA_BOOLEAN([1, 0, 0])).to_a
  end

  def test_mask_return_forms_on_a_writable_face_are_unchanged
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-01], unit: :D)
    assert_equal [UNDEF, "2024-01-02", UNDEF],
                 t.mask_eq(t[0]).to_a.map { |e| e.equal?(UNDEF) ? e : e.to_s }
    assert_equal [UNDEF, 2, UNDEF], CA_INT32([1, 2, 1]).mask_eq(1).to_a
  end

end
