# A face-mode CAObject's mask is a C view over its parent's mask, owned by
# the CAObject.  It was never freed (one mask struct per object, growing
# with ndim), and dup shared it with the original, so freeing it in one
# would have left the other pointing at freed memory.  The CAObject now
# frees its mask, and a dup makes its own from the parent.
#
# The leak is measured by utils/measure_leak.rb (macOS only): an 8-D mask
# struct is about 220 bytes, against a threshold of 64.

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestCAObjectFaceMaskFree < Test::Unit::TestCase

  FACE = "FaceObj = Class.new(CAObject) { def initialize (p) " \
         "super(CA_FLOAT64, p.shape, parent: p, face: true) end }"

  class FaceObj < CAObject
    def initialize (parent)
      super(CA_FLOAT64, parent.shape, parent: parent, face: true)
    end
  end

  def masked_parent
    p0 = CArray.float64(3, 4).seq
    p0[1, 2] = UNDEF
    p0
  end

  def bytes_per_call (expr)
    setup = FACE + "; pm = CArray.float64(2,2,2,2,2,2,2,2).seq; pm[1] = UNDEF; " \
            "x = FaceObj.new(pm); x.is_masked"
    bytes = LeakMeter.bytes_per_call(expr, setup: setup, calls: 5000, warmup: 500)
    omit "malloc zone statistics unavailable" if bytes.nil?
    bytes
  end

  def test_face_frees_its_mask
    grown = bytes_per_call("z = FaceObj.new(pm); z.is_masked")
    assert_operator grown, :<, 64, "grew #{grown.round} bytes per object"
  end

  def test_dup_frees_its_mask
    grown = bytes_per_call("y = x.dup; y.is_masked")
    assert_operator grown, :<, 64, "grew #{grown.round} bytes per dup"
  end

  def test_dup_outlives_the_original
    GC.stress = true
    p0 = masked_parent
    x = FaceObj.new(p0)
    x.is_masked
    y = x.dup
    z = FaceObj.new(p0).dup
    x = nil
    GC.start
    assert_equal p0.is_masked.to_a, y.is_masked.to_a
    assert_equal p0.is_masked.to_a, z.is_masked.to_a
  ensure
    GC.stress = false
  end

  def test_dup_writes_its_mask_through_the_parent
    p0 = masked_parent
    y = FaceObj.new(p0).dup
    y[0, 0] = UNDEF
    assert_equal true, p0.is_masked[0, 0]
    assert_instance_of FaceObj, y
  end

end
