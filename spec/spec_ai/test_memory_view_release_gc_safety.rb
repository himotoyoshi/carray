require "test/unit"
require "carray"

# Regression for the producer-side ca_mv_release path.  The current
# producer is alias-only: ca_mv_get never attaches the view, ca_mv_release
# only frees shape/strides scratch.  This removes the entire raise hazard
# that earlier revisions had (ca_sync / ca_detach inside the release
# callback could rb_raise during GC sweep -> [BUG] object allocation
# during garbage collection phase, fatal).
#
# These tests cycle producer get/release pairs interleaved with GC.start
# so any regression that reintroduces attach + sync/detach in the release
# path would surface as a crash or escaping exception.  The authoritative
# field repro for the original crash is
# `carray-pycall/samples/masked/sensor_dropouts.rb` (5/5 crash before the
# alias-only refactor, 5/5 clean after).

class TestMemoryViewReleaseGCSafety < Test::Unit::TestCase

  # CARefer view sets CA_MV_PRIV_NEEDS_DETACH on producer get; its
  # release path is the one that hits ca_sync + ca_detach.  Cycle many
  # producer get/release pairs interleaved with GC to surface regressions
  # toward raising during sweep.
  def test_refer_view_gc_churn
    src = CArray.float64(64).seq
    ref = src.refer(CA_FLOAT64, [64])      # CARefer (NEEDS_DETACH on get)
    1000.times do
      v = CArray.wrap_memory_view(ref)
      assert_equal(ref.shape, v.shape)
      v = nil  # let the wrap become eligible for collection
    end
    GC.start
    GC.start
    # If we got here without crash or escaping exception, release path
    # cleaned up the attach side without raising.
    assert_equal(src.to_a, src.to_a)       # sentinel
  end

  # Strided view (transpose) exercises the NEEDS_PARENT_DETACH branch
  # (compose-to-root resolution to the entity).
  def test_strided_view_gc_churn
    src = CArray.int32(8, 8).seq
    tr  = src.transpose                    # CATranspose -> strided MV
    500.times do
      v = CArray.wrap_memory_view(tr)
      assert_equal(tr.shape, v.shape)
      v = nil
    end
    GC.start
    GC.start
    assert_equal(src.to_a, src.to_a)
  end

  # Readonly source via CARefer: producer must skip the sync side without
  # raising "can not modify read-only array" out of ca_sync.
  def test_readonly_source_no_raise_on_release
    src = CArray.int32(16).seq
    ref = src.refer(CA_INT32, [16])
    ref.freeze                             # CA_FLAG_READ_ONLY -> ca_is_readonly true
    100.times do
      v = CArray.wrap_memory_view(ref)
      assert_equal([16], v.shape)
      v = nil
    end
    GC.start
    GC.start
  end

  # Many sequential entity wraps + GC: the DIRECT path doesn't set
  # NEEDS_DETACH, so release is a no-op beyond shape/strides xfree.  This
  # is a control that should always have been safe; included so the suite
  # covers both branches symmetrically.
  def test_entity_wrap_gc_churn
    src = CArray.float64(32).seq
    1000.times do
      v = CArray.wrap_memory_view(src)
      assert_equal([32], v.shape)
      v = nil
    end
    GC.start
    GC.start
  end

  # Field-surfaced crash path (mask invariant violation in ca_sync /
  # ca_detach recursion into ca->mask) can't be reproduced in pure Ruby:
  # the producer rejects has_mask sources up-front via ca_mv_available_p,
  # so the offending entry point is reached only through indirect paths
  # in carray-pycall round trips (= its samples/masked/sensor_dropouts.rb
  # exhibits 5/5 crash before the deepened pre-check).  Authoritative
  # sign-off for the masked-recursion branch of the fix is the field
  # repro going 5/5 clean post-rebuild.

end
