# A view taken through a Face, or through the lazy marker of `.lazy`, is
# moved one level down when it is lifted: its parent becomes the wrapper's
# parent, so the view no longer keeps the wrapper alive.  Its mask must move
# with it.  The mask was built over the wrapper's mask, which the wrapper
# frees with itself; left there, the view's mask read freed memory once the
# intermediate wrapper was collected (wrong mask bits, then crashes in
# each_slab and the kernel iterator).

require "test/unit"
require "carray"

class TestFaceLiftMaskParent < Test::Unit::TestCase

  def masked_time
    a = CArray.time(Array.new(20) { |i| "2024-01-#{(i % 9 + 1).to_s.rjust(2, '0')}" },
                    unit: :D).copy
    a[1] = UNDEF
    a[6] = UNDEF
    a
  end

  def under_gc_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  def test_view_mask_outlives_intermediate_face
    a = masked_time
    want = a.copy.reshape(4, 5)[nil, 1..3].mask.to_a
    got = under_gc_stress { a.reshape(4, 5)[nil, 1..3].mask.to_a }
    assert_equal want, got
  end

  def test_each_slab_over_masked_face_view
    a = masked_time
    want = a.copy.reshape(4, 5).count_masked(axis: 1).to_a
    got = []
    under_gc_stress do
      a.reshape(4, 5)[nil, :>].each { |row| got << row.copy.count_masked }
    end
    assert_equal want, got
  end

  def test_unmasked_then_masked_slab_walk
    vals = Array.new(20) { |i| "2024-01-#{(i % 9 + 1).to_s.rjust(2, '0')}" }
    under_gc_stress do
      [false, true].each do |masked|
        src = CArray.time(vals, unit: :D)
        if masked
          src = src.copy
          src[1] = UNDEF
          src[6] = UNDEF
        end
        pieces = []
        src.reshape(4, 5)[nil, :>].each { |p| pieces << p.copy }
        assert_equal (masked ? [1, 1, 0, 0] : [0, 0, 0, 0]),
                     pieces.map(&:count_masked)
      end
    end
  end

  def test_view_mask_outlives_intermediate_lazy_marker
    a = CArray.float64(20).seq
    a[1] = UNDEF
    a[6] = UNDEF
    want = a.reshape(4, 5)[nil, 1..3].is_masked.to_a
    got = under_gc_stress { a.lazy.reshape(4, 5)[nil, 1..3].is_masked.to_a }
    assert_equal want, got
  end

  def test_lazy_view_mask_stays_read_only
    a = CArray.float64(20).seq
    a[1] = UNDEF
    v = a.lazy.reshape(4, 5)[nil, 1..3]
    GC.start
    assert_raise(RuntimeError) { v.mask[0, 0] = 1 }
  end

end
