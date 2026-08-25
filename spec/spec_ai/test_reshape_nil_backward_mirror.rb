require "test/unit"
require "carray_ext"

# Regression: 2.0 reshape(*nil-mixed) two-sweep semantics.
#
# 2.0 transform.rb resolved nil dims with forward-then-backward sweeps,
# so trailing nils that ran past ndim picked up dim[ndim-1-k] from the
# tail. The 3.0 C port (ext/ca_obj_refer.c::rb_ca_reshape) initially
# collapsed this into a single forward map when no -1 placeholder was
# present, regressing b.reshape(1, nil) on b.ndim=1. This file pins
# the restored 2.0-compatible behavior.

class TestReshapeNilBackwardMirror < Test::Unit::TestCase

  def test_trailing_nil_on_1d_mirrors_tail
    b = CArray.int32(3).seq(2, 2)
    v = b.reshape(1, nil)
    assert_equal [1, 3], v.dim
    assert_equal [[2, 4, 6]], v.to_a
  end

  def test_inner_and_trailing_nil_no_placeholder
    a = CArray.int32(2, 3, 4).seq
    # nil resolves to the source dim: axis 0 → dim[0]=2, axis 2 → dim[2]=4.
    # 3.0 strict: the explicit middle must keep the element count, so the
    # only preserving value is dim[1]=3.
    assert_equal [2, 3, 4], a.reshape(nil, 3, nil).dim
    # The pre-3.0 shrinking form (nil, 2, nil → 16 ≠ 24) now raises.
    assert_raise(RuntimeError) { a.reshape(nil, 2, nil) }
  end

  def test_all_nil_identity
    a = CArray.int32(2, 3, 4).seq
    assert_equal [2, 3, 4], a.reshape(nil, nil, nil).dim
  end

  def test_nil_before_placeholder_keeps_forward
    a = CArray.int32(2, 3, 4).seq
    # nil at 0 → dim[0]=2, -1 infers 12
    assert_equal [2, 12], a.reshape(nil, -1).dim
  end

  def test_nil_after_placeholder_mirrors_from_end
    a = CArray.int32(2, 3, 4).seq
    # -1 infers 6 (= 24/4), nil at 1 → dim[ndim-1]=4
    assert_equal [6, 4], a.reshape(-1, nil).dim
  end

  def test_trailing_nil_beyond_ndim_2d_to_3d
    a = CArray.int32(2, 6).seq
    # axis 0 forward dim[0]=2, axis 2 trailing → dim[ndim-1]=6
    # axis 1 literal 1 → final [2, 1, 6]
    assert_equal [2, 1, 6], a.reshape(nil, 1, nil).dim
  end

  def test_nil_at_out_of_range_with_no_tail_match_raises
    # b.ndim=1, reshape(nil, nil, nil): forward dim[0]=3, then
    # trailing nil at i=1 → backward dim[ndim-(argc-i)]=dim[0]=3,
    # and at i=2 → dim[ndim-(3-2)]=dim[0]=3 → [3,3,3] = 27 ≠ 3.
    # That fails at refer size check, not at the nil resolution step.
    b = CArray.int32(3).seq
    assert_raise(RuntimeError) { b.reshape(nil, nil, nil) }
  end

  def test_view_shares_data
    b = CArray.int32(3).seq(2, 2)
    v = b.reshape(1, nil)
    v[0, 1] = 99
    assert_equal 99, b[1]
  end

end
