require "test/unit"
require "carray"

# CArray.wrap_memory_view takes the class of its result from the
# receiver.  Called on CArray it builds a CAWrap, as it always has;
# called on a subclass of CAWrap it builds that subclass, so a gem
# bridging a foreign buffer can name where the array came from.
#
# The class marks the provenance of the entry object only.  A view
# derived from it is a CABlock or a CAStride like any other, and that
# is deliberate -- a slice of a borrowed image is no longer the image.
# `dup` is left unpinned here: it returns an owning entity while
# keeping the class, which is a defect predating this surface, and
# pinning it would fix the defect in place.
#
# CArray itself is used as the producer, so these run without a
# third-party MemoryView gem.

class MVWrapClassSubclass < CAWrap
end

class TestMemoryViewWrapClass < Test::Unit::TestCase

  def setup
    @src = CArray.float64(3, 4).seq
  end

  # ---------------- the receiver picks the class ----------------

  def test_carray_receiver_builds_a_cawrap
    assert_equal CAWrap, CArray.wrap_memory_view(@src).class
  end

  def test_cawrap_receiver_builds_a_cawrap
    assert_equal CAWrap, CAWrap.wrap_memory_view(@src).class
  end

  def test_subclass_receiver_builds_that_subclass
    assert_equal MVWrapClassSubclass,
                 MVWrapClassSubclass.wrap_memory_view(@src).class
  end

  def test_data_type_class_still_forwards_to_carray
    # CArray::Float64 is not a CArray subclass; it forwards through
    # lib/carray/construct.rb, so the receiver is CArray again.
    assert_equal CAWrap, CArray::Float64.wrap_memory_view(@src).class
  end

  # ---------------- it is still an ordinary wrap ----------------

  def test_subclass_wrap_is_an_entity_of_the_wrap_obj_type
    w = MVWrapClassSubclass.wrap_memory_view(@src)
    assert_equal CA_OBJ_ARRAY_WRAP, w.obj_type
    assert w.entity?
  end

  def test_subclass_wrap_shares_memory_with_the_producer
    w = MVWrapClassSubclass.wrap_memory_view(@src)
    assert_equal @src.shape, w.shape
    assert_equal @src[2, 3], w[2, 3]
    w[0, 0] = 99.0
    assert_equal 99.0, @src[0, 0]
  end

  def test_subclass_wrap_still_exports_a_memory_view
    w = MVWrapClassSubclass.wrap_memory_view(@src)
    assert CArray.memory_view_available?(w)
    assert_equal @src.to_a, CArray.from_memory_view(w).to_a
  end

  def test_subclass_wrap_accepts_a_borrowed_mask
    mask = CArray.boolean(3, 4)
    mask[1, nil] = 1
    w = MVWrapClassSubclass.wrap_memory_view(@src, mask: mask)
    assert_equal MVWrapClassSubclass, w.class
    assert w.has_mask?
    assert_equal 4, w.count_masked
  end

  def test_derived_view_does_not_carry_the_class
    w = MVWrapClassSubclass.wrap_memory_view(@src)
    assert_equal CABlock, w[0..1, nil].class
  end

  # ---------------- refusals ----------------

  def test_receiver_outside_the_cawrap_line_is_refused
    # CScalar and the Face classes inherit the singleton method from
    # CArray, but none of them can be handed back from here.
    [CScalar, CATime].each do |klass|
      assert_raise(TypeError) { klass.wrap_memory_view(@src) }
    end
  end

  def test_strided_producer_is_refused_when_a_class_was_asked_for
    # A strided producer yields a CAStride over an inner CAWrap, which
    # is not the class the caller named, so refuse rather than return
    # something else under that name.
    assert_raise(ArgumentError) do
      MVWrapClassSubclass.wrap_memory_view(@src[nil, 0..2])
    end
  end

  def test_strided_producer_still_yields_a_castride_for_carray
    assert_equal CAStride, CArray.wrap_memory_view(@src[nil, 0..2]).class
  end

  def test_repeated_refusal_releases_the_acquired_view
    # The strided refusal happens after the MemoryView is acquired, so
    # it has to release before raising.  A leak here would show up as
    # the producer staying locked.
    500.times do
      begin
        MVWrapClassSubclass.wrap_memory_view(@src[nil, 0..2])
      rescue ArgumentError
      end
    end
    GC.start
    @src[1, 1] = 7.0
    assert_equal 7.0, @src[1, 1]
  end

end
