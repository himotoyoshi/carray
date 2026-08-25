require "test/unit"
require "carray"

# Regression: a byte-reinterpreting CARefer (a different data_type / bytes)
# over a *cold* view root must not hand its region request down to that root.
#
# ca_stride_func_xfer_all composes the leaf's strides to the fold boundary and,
# when the boundary is cold but region-capable, asks it for just that region
# instead of materialising all of it.  The request is stated in the root's own
# address space, so the counts it carries are read as root cells and answered
# with root->bytes apiece.  With a narrowing reinterpret (f64 view -> uint8
# view) that is 8x the caller's buffer: 6x24 uint8 cells requested from a 6x3
# f64 root delivered 1152 bytes into 144, corrupting the heap (reporter's case:
# `a.reshape(6, 3).refer(CA_UINT8, [6, 24])`, SEGV / malloc abort).
#
# Such a view addresses the root in units the root does not share, so it takes
# the whole-root materialise instead, which addresses it in bytes.  xfer_stride
# and fill_stride already decline the same way.
class TestReferReinterpretColdRoot < Test::Unit::TestCase

  # Reference values for the reinterpret: the same bytes read through an
  # entity, where the fold reaches a live ptr and the region path never runs.
  def reinterpret_reference(ca, data_type, dim)
    ca.copy.refer(data_type, dim).to_a
  end

  def test_narrowing_refer_over_cold_reshape
    a = CArray.float64(2, 3, 3).seq(1)
    v = a.reshape(6, 3)                       # cold CAStride, fold stops here
    r = v.refer(CA_UINT8, [6, 24])
    assert_equal reinterpret_reference(v, CA_UINT8, [6, 24]), r.to_a
    assert_equal v.to_a, r.copy.refer(CA_FLOAT64, [6, 3]).to_a
  end

  def test_narrowing_refer_over_cold_transpose
    t = CArray.float64(3, 4).seq(1).transpose  # cold, non-contiguous
    r = t.refer(CA_UINT8, [4, 24])
    assert_equal reinterpret_reference(t, CA_UINT8, [4, 24]), r.to_a
  end

  def test_widening_refer_over_cold_reshape
    u = CArray.uint8(4, 12).seq(0)
    v = u.reshape(6, 8)
    assert_equal v.to_a, v.refer(CA_FLOAT64, [6, 1]).refer(CA_UINT8, [6, 8]).to_a
  end

  def test_narrowing_refer_over_lazy_root
    lz = CArray.float64(12).seq(1).swap_bytes  # CAMonOp: cold and region-capable
    v  = lz.reshape(4, 3)
    assert_equal v.to_a, v.refer(CA_UINT8, [4, 24]).refer(CA_FLOAT64, [4, 3]).to_a
  end

  # PUT direction: writes through the reinterpret view reach the entity.
  def test_store_through_narrowing_refer_over_cold_reshape
    want  = CArray.float64(6, 3).seq(101)
    bytes = want.refer(CA_UINT8, [6, 24]).copy

    a = CArray.float64(2, 3, 3).seq(1)
    a.reshape(6, 3).refer(CA_UINT8, [6, 24])[] = bytes
    assert_equal want.to_a, a.reshape(6, 3).to_a
  end

  # The same-width neighbours keep taking the region path (values unchanged).
  def test_same_width_refer_over_cold_root_unchanged
    a = CArray.float64(2, 3, 3).seq(1)
    assert_equal a.reshape(3, 6).to_a, a.reshape(6, 3).refer(CA_FLOAT64, [3, 6]).to_a
  end
end
