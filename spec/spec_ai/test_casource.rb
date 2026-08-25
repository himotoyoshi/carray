# CASource — abstract marker class for parentless generate-entities.
#
# Two things are pinned here:
#
#   1. CASource itself: a class under CArray (not under CAView), sealed
#      against instantiation, carrying no behaviour of its own.
#   2. That a source class registered from outside the core works as a
#      CArray.  CASmokeSource (spec_ai/ext_source_smoke/) is an
#      external-bridge source over a buffer owned by a Ruby String:
#      CA_REAL_ARRAY, plain CArray prefix, no parent, complete operation
#      table of its own, cold at rest.
#
# The lifecycle assertions are the interesting half. A source over a
# foreign buffer has to notice when the backend re-shapes that buffer
# underneath it, and the only way that check runs on *every* path is to
# leave `ptr` NULL at rest: while `ptr` is published the core moves bytes
# straight through it and the source's own slots are bypassed. What is
# pinned here is that the guard fires everywhere, that a revoked buffer
# is refused everywhere, and that overlapping attach windows still work
# (which needs the fixture's hold counting, since entities carry no
# attach reference count of their own).
#
# See devel/PROPOSAL_CASOURCE.md §10.1.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_source_smoke", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "source_smoke"
rescue LoadError
  warn "Skipping test_casource: source_smoke not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestCASourceAbstract < Test::Unit::TestCase

  def test_placement_in_hierarchy
    assert_equal CArray, CASource.superclass
    assert_false CASource.ancestors.include?(CAView)
  end

  def test_not_instantiable
    assert_raise(TypeError) { CASource.new }
  end

  def test_carries_no_own_methods
    # The class is a marker: everything a source does comes from its own
    # obj_type, so CASource must add nothing to CArray.
    assert_equal [], CASource.instance_methods(false)
    assert_equal [], CASource.singleton_methods(false)
  end

end

class TestCASourceSubclass < Test::Unit::TestCase

  def setup
    @str = ("\0" * 12).dup
    @src = CASmokeSource.new(@str, [3, 4])
    @src.seq!(1)
  end

  # ----- identity -----------------------------------------------------

  def test_is_a_source_and_a_carray
    assert_kind_of CASource, @src
    assert_kind_of CArray, @src
    assert_false @src.is_a?(CAView)
  end

  def test_declares_itself_an_entity
    assert_true @src.entity?
  end

  def test_shape_and_data_type
    assert_equal [3, 4], @src.shape
    assert_equal CA_UINT8, @src.data_type
  end

  # ----- the foreign buffer is the storage ----------------------------

  def test_reads_the_owner_bytes
    assert_equal (1..12).to_a, @src.to_a.flatten
  end

  def test_writes_through_to_the_owner
    @src[1, 2] = 99
    assert_equal 99, @str.bytes[6]
  end

  def test_block_write_reaches_the_owner
    @src[1..2, 1..2] = 0
    assert_equal [1, 2, 3, 4, 5, 0, 0, 8, 9, 0, 0, 12], @str.bytes
  end

  def test_owner_write_is_seen_by_the_source
    @str.setbyte(0, 200)
    assert_equal 200, @src[0, 0]
  end

  # ----- the ordinary CArray surface ----------------------------------

  def test_reduction
    assert_equal 78, @src.sum
    assert_equal 12, @src.max
  end

  def test_per_axis_reduction
    assert_equal [15, 18, 21, 24], @src.sum(axis: 0).to_a
  end

  def test_binop_with_an_entity
    other = CArray.uint8(3, 4) { |i| 1 }
    assert_equal (2..13).to_a, (@src + other).to_a.flatten
  end

  def test_sort_and_order
    assert_equal (1..12).to_a, @src.sort.to_a
    assert_equal 11, @src.max_index
  end

  def test_views_over_a_source
    v = @src[1..2, 1..3]
    assert_kind_of CABlock, v
    assert_equal [[6, 7, 8], [10, 11, 12]], v.to_a
    v[] = 0
    assert_equal [1, 2, 3, 4, 5, 0, 0, 0, 9, 0, 0, 0], @str.bytes
  end

  def test_reshape_is_a_view_of_the_owner
    r = @src.reshape(2, 6)
    r[0, 0] = 77
    assert_equal 77, @str.bytes[0]
  end

  def test_mask
    m = @src.mask_eq(5)
    assert_equal 1, m.count_masked
    assert_equal 73, m.sum
  end

  def test_copy_is_independent
    c = @src.copy
    assert_kind_of CArray, c
    c[0, 0] = 42
    assert_equal 1, @str.bytes[0]
  end

  def test_to_ca_hands_back_self
    assert_same @src, @src.to_ca
  end

  def test_dup_shares_the_owner
    d = @src.dup
    assert_kind_of CASmokeSource, d
    d[0, 0] = 42
    assert_equal 42, @str.bytes[0]
  end

  # ----- lifecycle ----------------------------------------------------

  # Every way of touching the data, so the two sweeps below cannot go
  # stale by omission.
  PATHS = {
    "whole-view reduce"  => ->(s) { s.sum },
    "to_a"               => ->(s) { s.to_a },
    "sort"               => ->(s) { s.sort },
    "per-axis reduce"    => ->(s) { s.sum(axis: 0) },
    "binop"              => ->(s) { s + CArray.uint8(3, 4) { 1 } },
    "element read"       => ->(s) { s[1, 2] },
    "element write"      => ->(s) { s[1, 2] = 5 },
    "region read"        => ->(s) { s[1..2, 1..2].to_a },
    "region write"       => ->(s) { s[0..1, 0..1] = 6 },
    "fill"               => ->(s) { s[] = 1 },
    "copy"               => ->(s) { s.copy },
    "lazy chain"         => ->(s) { (s.lazy * 2).to_ca },
    "mask_eq"            => ->(s) { s.mask_eq(1) },
    "attach!"            => ->(s) { s.attach! { } },
  }

  def test_the_array_is_cold_at_rest
    assert_false @src.attached?
    assert_equal 0, @src.hold_count
  end

  def test_every_path_re_resolves_the_foreign_buffer
    PATHS.each do |name, op|
      @src.reset_counters
      op.call(@src)
      assert_operator @src.resolve_count, :>=, 1,
                      "#{name} did not reach the source's own slots"
    end
  end

  def test_every_path_returns_the_array_to_cold
    PATHS.each do |name, op|
      op.call(@src)
      assert_equal 0, @src.hold_count, "#{name} leaked a hold"
      assert_false @src.attached?, "#{name} left ptr published"
    end
  end

  def test_a_revoked_buffer_is_refused_everywhere
    PATHS.each do |name, op|
      str = ("\0" * 12).dup
      src = CASmokeSource.new(str, [3, 4])
      src.seq!(1)
      src.revoke!   # the backend re-shaped the buffer underneath
      assert_raise(RuntimeError, "#{name} accepted a revoked buffer") do
        op.call(src)
      end
    end
  end

  def test_a_view_held_across_a_revocation_is_refused_too
    v = @src[1..2, 1..2]
    @src.revoke!
    assert_raise(RuntimeError) { v.to_a }
  end

  def test_a_copy_taken_before_a_revocation_stays_valid
    c = @src.copy
    @src.revoke!
    assert_equal (1..12).to_a, c.to_a.flatten
  end

  # Entities carry no attach reference count, so without the fixture's
  # hold counting an inner attach/detach pair would clear ptr under an
  # outer holder and its sync would fail.
  def test_overlapping_attach_windows
    assert_equal 78, @src.attach! { @src.attach! { }; @src.sum }
    v = @src[1..2, nil]
    assert_equal [[5, 6, 7, 8], [9, 10, 11, 12]],
                 v.attach! { @src.sum; v.to_a }
    assert_equal 0, @src.hold_count
  end

  # Which consumers route through attach at all. Element access never
  # does — it reaches xfer_index directly — which is exactly why the
  # re-resolution check cannot live in attach alone.
  #
  # Nor does a partial fill any more: it arrives as a region and goes down
  # through fill_stride, so a source is no longer gathered and written back
  # whole to set a few of its cells.  A source that wants the region in one
  # piece rather than a cell at a time fills in the slot; either way it is
  # never asked for the cells the caller did not name.
  def test_observed_attach_routing
    counters = lambda do |&op|
      @src.reset_counters
      op.call
      [@src.attach_count, @src.sync_count, @src.detach_count]
    end
    assert_equal [1, 0, 1], counters.call { @src.sum }
    assert_equal [1, 0, 1], counters.call { @src[1..2, 1..2].to_a }
    assert_equal [0, 0, 0], counters.call { @src[1..2, 1..2] = 3 }
    assert_equal [1, 1, 1], counters.call { @src.attach! { } }
    assert_equal [0, 0, 0], counters.call { @src[1, 2] }
    assert_equal [0, 0, 0], counters.call { @src[1, 2] = 5 }
  end

  # And the values still land where they were asked to.
  def test_partial_fill_writes_only_its_region
    @src[1..2, 1..2] = 3
    assert_equal [[3, 3], [3, 3]], @src[1..2, 1..2].to_a
    assert_equal 1, @src[0, 0]
    assert_equal 12, @src[2, 3]
  end

  # ----- MemoryView ---------------------------------------------------

  def test_memory_view_is_declined_consistently
    # An obj_type installed from outside the core has no export strategy,
    # so availability and export must agree on "no".
    assert_false CArray.memory_view_available?(@src)
    assert_raise(ArgumentError) { CArray.from_memory_view(@src) }
  end

  # ----- ca_is_entity across the build boundary -----------------------

  # ca_is_entity indexes ca_func[], so expanding it inline fixes the array
  # stride at sizeof(ca_operation_function_t).  Sources built with carray get
  # the macro; this fixture is built separately and gets the function, which
  # is what keeps a later slot addition from re-indexing the table under an
  # extension that was not rebuilt.  Both forms must answer alike.
  def test_entity_predicate_agrees_across_the_build_boundary
    a = CArray.int32(4, 4) { |i| i }
    [ a,                       # entity
      a[1..2, nil],            # CABlock
      a.reshape(16),           # CARefer
      a.transpose,             # CATranspose
      a.fake(:uint8),          # CAFake  -- transform view
      a[a.gt(5)],              # CASelect
      a.to_type(:float64),     # entity again, different data_type
      @src,                    # the fixture's own installed obj_type
    ].each do |ca|
      assert_equal ca.entity?, CASmokeSource.entity_p(ca),
                   "disagreement for #{ca.class}"
    end
  end

end
