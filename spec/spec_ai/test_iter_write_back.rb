# Does a byte a kernel writes reach the user's array?
#
# Every kernel inside carray writes into an array it just allocated, so the
# iterator's WRITE half has only ever been exercised with a fresh entity as
# the destination.  A C extension using the author macros can hand it any
# view.  spec_ai/ext_iter_write/ is that caller, and this file walks the
# matrix it opens up.
#
# MOST OF THE ASSERTIONS BELOW PIN BEHAVIOUR THAT IS WRONG.  They are here
# so that the fixes land visibly: each one is expected to flip, and the test
# that flips it should be rewritten to assert the correct behaviour rather
# than deleted.  Tests whose name begins with `test_sound_` are the opposite
# -- they pin the invariant the working half rests on and must not change.
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

  def test_F3_a_rejected_init_can_return_silently
    # The author asked for an axis that does not exist and was told nothing
    # at all: the call returns normally, having written nothing.
    a = CArray.float64(3, 4).seq!(1)
    before = a.to_a.flatten
    assert_nothing_raised { CArray.iw_slab_fill(a, 9, -1.0) }
    assert_equal before, a.to_a.flatten
  end

  def test_F3_a_rejected_init_can_also_take_the_process_down
    # Which of the two happens is decided by which check inside init_l2
    # fires, since only some of them reach that branch's memset before
    # returning.  Poisoning the caller's frame does not change either
    # outcome, so this is a property of the reject site, not of luck.
    [['b.shift(1, 0)', 0], ['b[b.gt(0)]', 1]].each do |view, axis|
      %w[iw_slab_fill iw_slab_fill_poisoned].each do |entry|
        st = status_of(<<~RUBY)
          require "carray"
          require "iter_write"
          b = CArray.float64(3, 4).seq!(1)
          CArray.#{entry}(#{view}, #{axis}, -1.0)
        RUBY
        assert_not_nil st.termsig, "#{view} axis #{axis} via #{entry}"
      end
    end
  end

  # --- F-4: CAStack skips sync unconditionally --------------------------
  # ca_kernel_iterator.c:2757 skips sync for ALIAS_STACK / STACK_OUTER_K as
  # "READ-only scope", but init_l2:1389 / :1508 pick those modes without
  # looking at CA_KERNEL_WRITE.
  # EXPECTED TO FLIP: to a refusal (Step 2) or to 12 (Step 4).

  def test_F4_stack_loses_the_write_when_the_slab_axis_is_the_stack_axis
    mk = ->(b) { CArray.stack([b, b.copy], axis: 0) }
    assert_equal 0, cells_reached(mk, :iw_slab_fill, 0)
    assert_equal 0, cells_reached(mk, :iw_fiber_fill, 0)
    assert_equal 0, CArray.iw_init_rc(CArray.stack([base, base], axis: 0), 0, WRITE),
                 "and init does not refuse it"
  end

  def test_F4_stack_loses_half_the_write_on_another_axis
    # Worse than losing all of it: the fiber form lands 6 of the 12 cells
    # this parent owns, so the array is left half updated.
    mk = ->(b) { CArray.stack([b, b.copy], axis: 0) }
    assert_equal 6, cells_reached(mk, :iw_fiber_fill, 1)
    assert_equal 12, cells_reached(mk, :iw_slab_fill, 1)
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
