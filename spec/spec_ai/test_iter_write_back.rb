# Does a byte a kernel writes reach the user's array?
#
# Every kernel inside carray writes into an array it just allocated, so the
# iterator's WRITE half has only ever been exercised with a fresh entity as
# the destination.  A C extension using the author macros can hand it any
# view.  spec_ai/ext_iter_write/ is that caller, and this file walks the
# matrix it opens up.
#
# A test named `test_F<n>_` pins behaviour that is WRONG, so that the fix
# lands visibly: it is expected to flip, and whoever flips it rewrites it to
# assert the correct behaviour rather than deleting it.  Every other test
# pins behaviour that is correct -- `test_sound_` for the invariant the
# working half rests on, and plain names for what has since been fixed.
#
# The invariant that makes the sound cells sound: under CA_SLAB_WHOLE the
# gather extent and the scatter extent are the same, so what was collected
# is what gets pushed back.  Every broken cell below is a CA_SLAB_AXES path
# that broke that equality -- it gathers slab-sized or fiber-sized and then
# scatters whole-view, or does not scatter at all.
#
# See devel/PROPOSAL_ITER_WRITE_BACK.md.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_write", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_write"
rescue LoadError
  warn "Skipping test_iter_write_back: iter_write not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterWriteBack < Test::Unit::TestCase

  WRITE        = 0x1
  FIBER_FLAGS  = 0x1 | 0x2 | 0x8   # WRITE | NO_MASK | FIBER_CONTIG

  def base
    CArray.float64(3, 4).seq!(1)
  end

  # Number of cells of the base entity that the fill actually reached.
  def cells_reached (view_of, entry, axis)
    b = base
    v = view_of.call(b)
    before = b.to_a.flatten
    CArray.send(entry, v, axis, -1.0)
    before.zip(b.to_a.flatten).count { |x, y| x != y }
  end

  # Run one case in a child process, because it takes the process down.
  # Returns the child's exit status.
  def status_of (script)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    system(RbConfig.ruby, *inc, "-e", script,
           out: File::NULL, err: File::NULL)
    $?
  end

  def child (build_view, entry, axis)
    <<~RUBY
      require "carray"
      require "iter_write"
      b = CArray.float64(3, 4).seq!(1)
      CArray.#{entry}(#{build_view}, #{axis}, -1.0)
    RUBY
  end

  # --- the working half: gather extent == scatter extent ----------------

  def test_sound_entity_and_stride_family_receive_every_write
    {
      "entity"    => ->(b) { b },
      "refer"     => ->(b) { b.refer(:float64, [3, 4]) },
      "block"     => ->(b) { b[nil, 1..3] },
      "transpose" => ->(b) { b.transpose },
      "grid"      => ->(b) { b[[0, 2], [1, 3]] },
      "window"    => ->(b) { b.window(0..1, 0..1) },
    }.each do |name, mk|
      n = mk.call(base).elements
      [0, 1].each do |axis|
        assert_equal n, cells_reached(mk, :iw_fiber_fill, axis),
                     "#{name} fiber axis #{axis}"
        assert_equal n, cells_reached(mk, :iw_slab_fill, axis),
                     "#{name} slab axis #{axis}"
      end
    end
  end

  def test_sound_slab_axes_without_fiber_contig_reaches_transform_views
    # The same views that lose fiber writes (below) are fine without
    # FIBER_CONTIG: the whole-view scratch is gathered and scattered with
    # the same extent.
    {
      "fake"  => ->(b) { b.fake(:float64) },
      "swap"  => ->(b) { b.swap_bytes },
      "roll"  => ->(b) { b.roll(1, 0) },
      "tile"  => ->(b) { b.tile(1, 1) },
    }.each do |name, mk|
      [0, 1].each do |axis|
        assert_equal 12, cells_reached(mk, :iw_slab_fill, axis),
                     "#{name} slab axis #{axis}"
      end
    end
  end

  def test_sound_readonly_destination_is_refused
    assert_equal 4, CArray.iw_init_rc(base.lazy + 1, 0, WRITE)
  end

  # --- F-2: SRC_ATTACH + FIBER_CONTIG drops a non-contiguous fiber ------
  # ca_kernel_iterator.c:2773 pushes back the untouched whole-view scratch
  # and returns before the per-fiber scatter at :2836.
  # EXPECTED TO FLIP: every count below should become 12.

  def test_F2_fiber_write_is_lost_on_the_outer_axis
    {
      "swap" => ->(b) { b.swap_bytes },
      "roll" => ->(b) { b.roll(1, 0) },
      "tile" => ->(b) { b.tile(1, 1) },
    }.each do |name, mk|
      assert_equal 0, cells_reached(mk, :iw_fiber_fill, 0),
                   "#{name}: write is currently lost"
      # The contiguous fiber on the same view is fine.
      assert_equal 12, cells_reached(mk, :iw_fiber_fill, 1), "#{name} inner"
    end
  end

  def test_F2_fake_loses_the_outer_fiber_too
    # Split from the others because its inner axis crashes (F-1).
    assert_equal 0, cells_reached(->(b) { b.fake(:float64) }, :iw_fiber_fill, 0)
  end

  # --- F-1: PER_FIBER_FUSED has no scratch, and :2773 pushes back NULL --
  # EXPECTED TO FLIP: the child should exit 0 and write all 12 cells.

  def test_F1_fused_fiber_write_crashes_the_process
    st = status_of(child('b.fake(:float64)', "iw_fiber_fill", 1))
    assert_not_predicate st, :success?,
                         "fused fiber write currently takes the process down"
  end

  # --- F-3: the block macros discard init's return code -----------------
  # ca_kernel_iterator.h:761 and the FIBER family: the rc is dropped and
  # the loop walks a state struct init_l2 returned without writing to.
  # EXPECTED TO FLIP: both children should fail with a Ruby exception
  # (loud refusal), not a signal.

  def test_F3_init_rejects_are_reported_by_init_itself
    assert_equal 2, CArray.iw_init_rc(base, 9, WRITE), "axis out of range"
    assert_equal 2, CArray.iw_init_rc(base, -1, WRITE), "negative axis"
    assert_equal 2, CArray.iw_init_rc(base[base.gt(0)], 1, WRITE), "1-D view, axis 1"
    assert_equal 3, CArray.iw_init_rc(base.shift(1, 0), 0, WRITE), "shift + WRITE"
    assert_equal 0, CArray.iw_init_rc(base.shift(1, 0), 0, 0), "shift READ is fine"
  end

  def test_a_rejected_init_says_so
    b = CArray.float64(3, 4).seq!(1)
    {
      "axis past the end" => [b, 9],
      "negative axis"     => [b, -1],
      "axis 1 of a 1-D view" => [b[b.gt(0)], 1],
      "shift as a WRITE destination" => [b.shift(1, 0), 0],
      "read-only destination" => [b.lazy + 1, 0],
    }.each do |what, (view, axis)|
      e = assert_raise(RuntimeError, what) do
        CArray.iw_slab_fill(view, axis, -1.0)
      end
      assert_match(/kernel iterator: .+ \(rc=\d+\)/, e.message, what)
    end
  end

  def test_a_rejected_init_leaves_the_destination_alone
    a = CArray.float64(3, 4).seq!(1)
    before = a.to_a.flatten
    assert_raise(RuntimeError) { CArray.iw_slab_fill(a, 9, -1.0) }
    assert_equal before, a.to_a.flatten
  end

  def test_a_rejected_init_does_not_depend_on_the_callers_frame
    # init writes the state before it can return, so a caller whose frame
    # is already dirty gets the same refusal as one sitting on clean stack
    # -- it used to get a dead process.
    st = status_of(<<~RUBY)
      require "carray"
      require "iter_write"
      b = CArray.float64(3, 4).seq!(1)
      begin
        CArray.iw_slab_fill_poisoned(b.shift(1, 0), 0, -1.0)
      rescue RuntimeError
        exit 0
      end
      exit 1
    RUBY
    assert_nil st.termsig, "no signal"
    assert_predicate st, :success?, "refused, not crashed"
  end

  # --- F-4 was: CAStack skipped sync unconditionally --------------------
  # ca_kernel_iterator.c:2795 skips sync for ALIAS_STACK / STACK_OUTER_K,
  # and init_l2 used to pick those modes without looking at CA_KERNEL_WRITE.
  # Declining them for WRITE routes a write destination through the generic
  # SRC_ATTACH path, which gathers and scatters the whole view -- so what is
  # left is F-2, which stack now shares with the rest of that family.

  def test_stack_receives_the_slab_write_on_every_axis
    mk = ->(b) { CArray.stack([b, b.copy], axis: 0) }
    [0, 1, 2].each do |axis|
      assert_equal 12, cells_reached(mk, :iw_slab_fill, axis), "axis #{axis}"
    end
  end

  def test_F2_stack_loses_the_fiber_write_like_the_other_attach_views
    mk = ->(b) { CArray.stack([b, b.copy], axis: 0) }
    assert_equal 0, cells_reached(mk, :iw_fiber_fill, 0)
    assert_equal 0, cells_reached(mk, :iw_fiber_fill, 1)
    # The contiguous fiber is fine, as it is for every other view here.
    assert_equal 12, cells_reached(mk, :iw_fiber_fill, 2)
  end

  def test_stack_over_view_parents_receives_the_write
    # The case that used to lose the write silently: STACK_OUTER_K aliased
    # parents[k]->ptr, which for a view parent is the attach buffer, and
    # finish detached it without syncing.
    r1 = CArray.float64(3, 8).seq!(1)
    r2 = CArray.float64(3, 8).seq!(100)
    s = CArray.stack([r1[nil, 0...4], r2[nil, 0...4]], axis: 0)
    before = r1.to_a.flatten + r2.to_a.flatten
    CArray.iw_slab_fill(s, 1, -1.0)
    after = r1.to_a.flatten + r2.to_a.flatten
    assert_equal 24, before.zip(after).count { |x, y| x != y }
  end

  def test_masked_stack_receives_the_write_and_keeps_its_mask
    a = CArray.float64(3, 4).seq!(1)
    a[0, 0] = UNDEF
    CArray.iw_slab_fill(CArray.stack([a, CArray.float64(3, 4).seq!(50)], axis: 0),
                        1, -1.0)
    assert_equal 1, a.count_masked
    assert_equal(-1.0, a.value[1, 1])
  end

  # --- F-5: the yielded mask is a snapshot of the input ------------------
  # alias_mask is scratch_mask (a ca_copy_data snapshot) at every site that
  # assigns it, and no branch of sync_slab scatters it.
  # EXPECTED TO STAY, as a contract: the decision is that a WRITE kernel
  # authors its output mask with ca_create_mask(co), not through the yield.
  # What should change is that the signature stops looking symmetric.

  def test_F5_mask_written_through_the_yield_does_not_reach_the_array
    a = CArray.float64(3, 4).seq!(1)
    a[0, 0] = UNDEF
    yielded = CArray.iw_slab_fill_mask(a, 0, -1.0)
    assert_equal true, yielded, "a mask pointer is handed to the kernel"
    assert_equal 1, a.count_masked, "but writing through it changes nothing"
    assert_equal(-1.0, a.value[1, 1], "while the data half of the same yield lands")
  end

  def test_F5_an_unmasked_destination_yields_no_mask_to_write
    # Why making the yielded mask writable would only be half a feature:
    # there is nothing to write into when the destination has no mask.
    a = CArray.float64(3, 4).seq!(1)
    assert_equal false, CArray.iw_slab_fill_mask(a, 0, -1.0)
    assert_equal 0, a.count_masked
  end

end
