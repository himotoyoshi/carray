# ca_iter_register_source_kind — how a view class installed from outside
# the core tells the kernel iterator how to read it.
#
# The classifier recognises carray's own views by comparing their
# operation table against a list compiled into the engine.  A class
# installed by a companion gem matches nothing there, so before this hook
# existed it classified as CA_ITER_SRC_NONE and every kernel that goes
# through the iterator refused the array (CA_ITER_ERR_NOT_CHEAP, rc=1).
# The break was uneven, which is what made it hard to read from the
# outside: an entity-typed external source still worked (it is caught by
# ca_is_entity first) and a slice of the offending view worked (the
# CABlock is classified on its own obj_type), but the whole array failed.
#
# The fixture (spec_ai/ext_iter_source_kind/) is a pair of identical
# conversion-layer views over an int32 parent — CAIterOffset registers,
# CAIterOffsetUnregistered does not — plus a CAStride-family view that
# registers and must be ignored.
#
# See guides/devel/08_view_catalog.md, "Telling the kernel iterator how to
# read it".

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_source_kind", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_source_kind"
rescue LoadError
  warn "Skipping test_iter_source_kind: iter_source_kind not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterSourceKindRegistered < Test::Unit::TestCase

  def setup
    @parent = CA_INT32([[1, 2, 3], [4, 5, 6]])
    @view   = CAIterOffset.wrap(@parent, 100)
  end

  def test_the_view_itself_reads_correctly
    assert_equal [[101, 102, 103], [104, 105, 106]], @view.to_a
  end

  # The failing call from the report: a reduction over the whole view.
  def test_reduction_over_the_whole_view
    assert_equal 621.0, @view.sum
    assert_equal 101, @view.min
    assert_equal 106, @view.max
    assert_equal 103.5, @view.mean
  end

  def test_per_axis_reduction
    assert_equal [205, 207, 209], @view.sum(axis: 0).to_a
    assert_equal [306, 315], @view.sum(axis: 1).to_a
  end

  def test_scan_kernel
    assert_equal [101, 203, 306, 410, 515, 621], @view.cumsum.to_a
  end

  def test_order_kernel
    assert_equal [[0, 0, 0], [1, 1, 1]], @view.sort_index.to_a
  end

  # A slice worked even before the hook (the CABlock is classified on its
  # own obj_type); it must keep working, and agree with the whole view.
  def test_slice_agrees_with_the_whole_view
    assert_equal 416.0, @view[0..1, 1..2].sum
    assert_equal @view.sum, @view[nil, nil].sum
  end

  def test_mask_propagates_through_the_kernel
    parent = CA_INT32([1, 2, 3, 4])
    parent[1] = UNDEF
    view = CAIterOffset.wrap(parent, 10)

    assert_equal [11, UNDEF, 13, 14], view.to_a
    assert_equal 1, view.count_masked
    assert_equal 38.0, view.sum         # masked cell excluded
  end

  # Registering declares how the view is *read*; it does not make it
  # read-only, and writes still land in the parent.
  def test_write_through_to_the_parent
    @view[0, 0] = 200
    assert_equal 100, @parent[0, 0]
    assert_equal 200, @view[0, 0]
  end

end

class TestIterSourceKindUnregistered < Test::Unit::TestCase

  def setup
    @parent = CA_INT32([[1, 2, 3], [4, 5, 6]])
    @view   = CAIterOffsetUnregistered.wrap(@parent, 100)
  end

  # The state a companion gem is in without the hook.  Pinned so the
  # registration in the twin class above is doing the work, not something
  # else the fixture happens to provide.
  def test_kernels_refuse_an_unregistered_external_view
    assert_raise(RuntimeError) { @view.sum }
    assert_raise(RuntimeError) { @view.mean }
  end

  # ... while everything that does not route through the iterator is
  # unaffected, which is what made the break confusing to read.
  def test_non_kernel_paths_still_work
    assert_equal [[101, 102, 103], [104, 105, 106]], @view.to_a
    assert_equal 101, @view[0, 0]
  end

  def test_a_slice_of_it_still_reaches_a_kernel
    assert_equal 416.0, @view[0..1, 1..2].sum
  end

end

class TestIterSourceKindRegistration < Test::Unit::TestCase

  # CA_ITER_SRC_ATTACH is the only kind an external class can honour on
  # its own.  SRC_DESCRIPTOR needs a describe_axes function the engine
  # looks up in its own table; SRC_CASTRIDE asserts the struct is one.
  # Both are refused rather than accepted and then not honoured.
  def test_only_src_attach_may_be_registered
    err = assert_raise(ArgumentError) do
      CAIterOffset.register(CA_OBJ_ITER_OFFSET_UNREG, CA_ITER_SRC_DESCRIPTOR)
    end
    assert_match(/only CA_ITER_SRC_ATTACH/, err.message)
  end

  def test_a_refused_registration_does_not_take_effect
    begin
      CAIterOffset.register(CA_OBJ_ITER_OFFSET_UNREG, CA_ITER_SRC_DESCRIPTOR)
    rescue ArgumentError
    end
    view = CAIterOffsetUnregistered.wrap(CA_INT32([1, 2, 3]), 100)
    assert_raise(RuntimeError) { view.sum }
  end

  def test_obj_type_is_range_checked
    assert_raise(ArgumentError) do
      CAIterOffset.register(CA_OBJ_TYPE_MAX_CONST, CA_ITER_SRC_ATTACH)
    end
    assert_raise(ArgumentError) do
      CAIterOffset.register(-1, CA_ITER_SRC_ATTACH)
    end
  end

  # Where the lookup sits.  CAIterStrideRegistered is a CAStride-family
  # view that registers anyway, with attach overridden to raise: the
  # classifier must recognise it structurally and read its strides
  # directly, so the registration is a no-op.  If the table were
  # consulted first, the view would be materialised and attach would
  # fire.
  def test_registration_does_not_divert_a_castride_family_source
    view = CAIterStrideRegistered.wrap(CA_INT32([[1, 2, 3], [4, 5, 6]]))
    assert_equal 21.0, view.sum
    assert_equal 1, view.min
    assert_equal 6, view.max
  end

end
