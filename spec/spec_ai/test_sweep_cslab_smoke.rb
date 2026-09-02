# spec_ai/test_sweep_cslab_smoke.rb
#
# Regression pin for the chunked slab family (`ca_call_cslab_N` /
# `ca_call_cslab_N_r`).  Where the cfunc family hands the author one cell,
# these hand it one chunk -- base / stride per operand, a cell count, and
# the chunk's slice of the iteration mask -- and drive the chunked sweep
# path (ca_sweep_acquire_chunked / ca_sweep_next_chunk /
# ca_sweep_release_chunked) rather than the whole-buffer one.
#
# What is pinned here is the part an author can get wrong silently: that a
# walk crossing chunk boundaries computes what a single-chunk walk does,
# that a non-alias INPUT re-gathered per chunk agrees with one materialised
# whole, and that the mask slice lines up with the chunk it was handed with.

require "test/unit"
require "carray"

# Fixture at ext_cslab_smoke/ is a byte-for-byte mirror of the user-facing
# example examples/c-extensions/cslab/, so this exercises the public API
# through the same pathway a real consumer ext uses.
ext_dir = File.expand_path("ext_cslab_smoke", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "cslab"
rescue LoadError
  warn "[skip] test_sweep_cslab_smoke.rb: cslab fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepCslabSmoke < Test::Unit::TestCase

  # The fixture computes out = a + b * scale and reports the walk as
  # [out, chunks, largest chunk, gathered?].
  def add_scaled (out, a, b, scale)
    CArray.demo_cslab_3_r(out, a, b, scale)
  end

  # A chunk is ~32KB, so this many float64 cells is several chunks whatever
  # the exact policy is.  Kept modest: the point is crossing boundaries, not
  # the size of the walk.
  CROSSES_CHUNKS = 100_000

  # ---------- the arithmetic ----------

  def test_single_chunk
    a = CArray.float64(5){|i| (i + 1).to_f}
    b = CArray.float64(5){|i| (i + 1).to_f * 0.5}
    out = CArray.float64(5)
    result, chunks, = add_scaled(out, a, b, 2.0)
    assert_equal [2.0, 4.0, 6.0, 8.0, 10.0], result.to_a
    assert_equal 1, chunks
  end

  def test_output_is_the_first_operand
    # fsync "100": operand 0 is the OUTPUT, and the call returns it.
    out = CArray.float64(3)
    result, = add_scaled(out, CArray.float64(3).seq, CArray.float64(3).seq, 1.0)
    assert_same out, result
  end

  # ---------- crossing chunk boundaries ----------

  def test_many_chunks_agree_with_the_array_expression
    n = CROSSES_CHUNKS
    a = CArray.float64(n).seq
    b = CArray.float64(n).seq(0.5, 0.5)
    out = CArray.float64(n)
    result, chunks, chunk_n_max, = add_scaled(out, a, b, 2.0)
    assert_operator chunks, :>, 1, "expected the walk to cross chunk boundaries"
    assert_operator chunk_n_max, :<, n, "expected chunks smaller than the walk"
    assert_equal (a + b * 2.0).to_a, result.to_a
  end

  def test_every_cell_is_visited_exactly_once
    # A chunk walk that dropped or repeated a boundary cell would still
    # produce plausible-looking data, so count the cells rather than eyeball
    # them: writing into a pre-filled output makes an unwritten cell visible.
    n = CROSSES_CHUNKS
    a = CArray.float64(n).seq
    b = CArray.float64(n) { 0.0 }
    out = CArray.float64(n) { -1.0 }
    result, = add_scaled(out, a, b, 1.0)
    assert_equal [], result.eq(-1.0).where.to_a,
                 "some cell was never written"
    assert_equal a.to_a, result.to_a
  end

  def test_chunk_size_does_not_scale_with_the_walk
    # The memory claim, stated as behaviour: a walk ten times longer is ten
    # times as many chunks, not chunks ten times as large.
    _, small_chunks, small_max, = add_scaled(CArray.float64(CROSSES_CHUNKS),
                                             CArray.float64(CROSSES_CHUNKS).seq,
                                             CArray.float64(CROSSES_CHUNKS).seq,
                                             1.0)
    big = CROSSES_CHUNKS * 10
    _, big_chunks, big_max, = add_scaled(CArray.float64(big),
                                         CArray.float64(big).seq,
                                         CArray.float64(big).seq,
                                         1.0)
    assert_equal small_max, big_max
    assert_operator big_chunks, :>, small_chunks
  end

  # ---------- operand kinds ----------

  def test_scalar_broadcast
    # A scalar operand collapses to stride 0, so its base must stay put
    # across chunks rather than walking with the others.
    n = CROSSES_CHUNKS
    a = CArray.float64(n).seq
    b = CScalar.float64; b[0] = 3.0
    out = CArray.float64(n)
    result, chunks, = add_scaled(out, a, b, 2.0)
    assert_operator chunks, :>, 1
    assert_equal (a + 6.0).to_a, result.to_a
  end

  def test_view_as_output_and_as_input
    grid = CArray.float64(3, 5).seq
    src  = CArray.float64(3, 5).seq(100.0)
    b    = CArray.float64(3) { |i| (i + 1).to_f * 0.5 }
    add_scaled(grid[nil, 2], src[nil, 2], b, 2.0)
    assert_equal [103.0, 109.0, 115.0], grid[nil, 2].to_a
    # the rest of the grid is untouched
    assert_equal [0.0, 1.0, 3.0, 4.0], grid[0, nil].to_a - [103.0]
  end

  def test_non_alias_input_gathered_per_chunk
    # A gather view cannot be walked in place, so each chunk is re-gathered
    # into the arena scratch.  `gathered` reads that off the callback's own
    # eyes: operand 1's base does not move between chunks exactly when it
    # was re-gathered.  The values must still match the whole-buffer answer.
    n = CROSSES_CHUNKS
    src = CArray.float64(n).seq
    input = src[CArray.int32(n).seq.reverse]
    b = CArray.float64(n).seq(0.5, 0.5)
    out = CArray.float64(n)
    result, chunks, _, gathered = add_scaled(out, input, b, 2.0)
    assert_operator chunks, :>, 1
    assert_equal true, gathered, "expected the gather view to take the scratch path"
    assert_equal (input.to_ca + b * 2.0).to_a, result.to_a
  end

  def test_entity_input_is_walked_in_place
    n = CROSSES_CHUNKS
    a = CArray.float64(n).seq
    b = CArray.float64(n).seq(0.5, 0.5)
    result, _, _, gathered = add_scaled(CArray.float64(n), a, b, 2.0)
    assert_equal false, gathered, "an entity INPUT needs no scratch"
    assert_equal (a + b * 2.0).to_a, result.to_a
  end

  # ---------- masks ----------

  def test_masked_input_within_one_chunk
    a = CArray.float64(5){|i| (i + 1).to_f}
    a[2] = UNDEF
    b = CArray.float64(5){|i| (i + 1).to_f * 0.5}
    out = CArray.float64(5)
    result, = add_scaled(out, a, b, 2.0)
    assert_equal [false, false, true, false, false], result.is_masked.to_a
    assert_equal [2.0, 4.0, 8.0, 10.0],
                 result.to_a.reject { |v| v == UNDEF }
  end

  def test_mask_slice_lines_up_with_its_chunk
    # m0 is built at full size and sliced per chunk, so an off-by-chunk_off
    # would mask the wrong cells -- and only past the first chunk, which is
    # why this has to cross a boundary to be worth pinning.
    n = CROSSES_CHUNKS
    a = CArray.float64(n).seq
    masked_at = [0, 1, n / 3, n / 2, n - 1]
    masked_at.each { |i| a[i] = UNDEF }
    b = CArray.float64(n) { 0.0 }
    out = CArray.float64(n)
    result, chunks, = add_scaled(out, a, b, 1.0)
    assert_operator chunks, :>, 1
    assert_equal masked_at.sort, result.is_masked.where.to_a
  end
  # ---------- the typed dispatcher, ca_call_cslab_M_N ----------

  def test_typed_allocates_its_own_output
    y, = CArray.demo_cslab_1_1_r(CArray.float64(5).seq(1.0), 10.0)
    assert_equal [10.0, 20.0, 30.0, 40.0, 50.0], y.to_a
    assert_equal "float64", y.data_type_name
  end

  def test_typed_coerces_the_input_to_the_declared_type
    # The callback reads doubles; the caller passed int32.  The dispatcher's
    # readonly cast view is what bridges them, and the output takes the
    # declared output type rather than the input's.
    y, = CArray.demo_cslab_1_1_r(CArray.int32(5).seq(1), 10.0)
    assert_equal [10.0, 20.0, 30.0, 40.0, 50.0], y.to_a
    assert_equal "float64", y.data_type_name
  end

  def test_typed_rank_zero_returns_a_number
    y, = CArray.demo_cslab_1_1_r(CScalar.float64.tap { |s| s[0] = 3.0 }, 10.0)
    assert_equal 30.0, y
    assert_kind_of Float, y
  end

  def test_typed_coercion_takes_the_gather_path
    # This is the memory claim for the typed layer, stated as behaviour: a
    # cast view is never attach-alias, so coercion is exactly the operand
    # kind the whole-buffer path would copy whole.  Pinning it keeps a later
    # change to wrap_readonly from silently turning the typed layer back
    # into a whole-array copy.
    n = CROSSES_CHUNKS
    y, chunks, gathered = CArray.demo_cslab_1_1_r(CArray.int32(n).seq, 2.0)
    assert_operator chunks, :>, 1
    assert_equal true, gathered, "expected the cast view to take the scratch path"
    assert_equal (CArray.int32(n).seq.float64 * 2.0).to_a, y.to_a
  end

  def test_typed_without_coercion_is_walked_in_place
    n = CROSSES_CHUNKS
    y, _, gathered = CArray.demo_cslab_1_1_r(CArray.float64(n).seq, 2.0)
    assert_equal false, gathered, "a float64 input needs no cast and no scratch"
    assert_equal (CArray.float64(n).seq * 2.0).to_a, y.to_a
  end

  def test_typed_agrees_with_the_per_cell_dispatcher
    n = CROSSES_CHUNKS
    x = CArray.int32(n).seq
    slab, = CArray.demo_cslab_1_1_r(x, 2.0)
    cell  = CArray.demo_cfunc_1_1_r(x, 2.0)
    assert_equal cell.to_a, slab.to_a
  end
end
