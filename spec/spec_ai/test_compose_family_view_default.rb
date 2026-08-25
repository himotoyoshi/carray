# Compose family view-default tests (S.2 / PROPOSAL_CASTACK.md)
# AC2.1 - AC2.8 acceptance criteria

require 'test/unit'
require 'carray'

class TestComposeFamilyViewDefault < Test::Unit::TestCase

  def setup
    @a = CArray.float64(3, 4) { |i, j| i * 10 + j }
    @b = CArray.float64(3, 4) { |i, j| 100 + i * 10 + j }
    @c = CArray.float64(3, 4) { |i, j| 200 + i * 10 + j }
    @d = CArray.float64(3, 4) { |i, j| 300 + i * 10 + j }
  end

  # ------------ AC2.1: view-default returns view chain (not eager) ------------

  def test_bind_returns_view
    v = CArray.meld([@a, @b, @c], axis: 0)
    refute_equal CArray, v.class    # view class, not the entity CArray
    assert_equal [9, 4], v.shape
  end

  def test_merge_returns_view
    v = CArray.stack([@a, @b, @c], axis: 0)
    refute_equal CArray, v.class
    assert_equal [3, 3, 4], v.shape
  end

  def test_montage_returns_view
    v = CArray.montage([@a, @b, @c, @d], [2, 2], axis: 0)
    refute_equal CArray, v.class
    assert_equal [6, 8], v.shape
  end

  # ------------ AC2.2: at = 0 / middle / negative all yield correct shape ------------

  def test_bind_axis_variants
    assert_equal [9, 4],  CArray.meld([@a, @b, @c], axis: 0).shape
    assert_equal [3, 12], CArray.meld([@a, @b, @c], axis: 1).shape
    assert_equal [3, 12], CArray.meld([@a, @b, @c], axis: -1).shape
  end

  def test_merge_axis_variants
    assert_equal [3, 3, 4], CArray.stack([@a, @b, @c], axis: 0).shape
    assert_equal [3, 3, 4], CArray.stack([@a, @b, @c], axis: 1).shape
    assert_equal [3, 4, 3], CArray.stack([@a, @b, @c], axis: 2).shape
    assert_equal [3, 4, 3], CArray.stack([@a, @b, @c], axis: -1).shape
  end

  # ------------ AC2.3: bit-exact match with old eager (= legacy paste path) ------------

  def test_bind_at0_values_correct
    v = CArray.meld([@a, @b, @c], axis: 0).to_ca
    # row 0 = a[0,:], row 3 = b[0,:], row 6 = c[0,:]
    assert_equal 0.0,   v[0, 0]
    assert_equal 100.0, v[3, 0]
    assert_equal 200.0, v[6, 0]
    assert_equal 23.0,  v[2, 3]
    assert_equal 123.0, v[5, 3]
    assert_equal 223.0, v[8, 3]
  end

  def test_bind_at1_values_correct
    v = CArray.meld([@a, @b, @c], axis: 1).to_ca
    # col 0 = a[:,0], col 4 = b[:,0], col 8 = c[:,0]
    assert_equal 0.0,   v[0, 0]
    assert_equal 100.0, v[0, 4]
    assert_equal 200.0, v[0, 8]
  end

  def test_combine_2x2_values_correct
    v = CArray.montage([@a, @b, @c, @d], [2, 2], axis: 0).to_ca
    # (0..2, 0..3) = a, (0..2, 4..7) = b, (3..5, 0..3) = c, (3..5, 4..7) = d
    assert_equal 0.0,   v[0, 0]
    assert_equal 100.0, v[0, 4]
    assert_equal 200.0, v[3, 0]
    assert_equal 300.0, v[3, 4]
  end

  # ------------ AC2.4: non-uniform NON-MELD axis raises ArgumentError ------------
  # (meld_axis is allowed to differ — that's the ragged case.  Only the
  # non-meld axes must agree.  Old CArray.meld required all axes uniform;
  # the new CAMeld-backed surface relaxes the meld axis while keeping
  # non-meld axes strict.)

  def test_bind_non_uniform_non_meld_axis_raises
    bad = CArray.float64(2, 5) { 999.0 }   # dim[0]=2 ok (ragged), dim[1]=5 ≠ 4 (bad)
    assert_raise(ArgumentError) { CArray.meld([@a, bad], axis: 0) }
  end

  def test_bind_ragged_meld_axis_accepted
    # dim[0] differs (3 vs 2) but non-meld axis 1 matches — ragged concat OK.
    bad = CArray.float64(2, 4) { 999.0 }
    v = CArray.meld([@a, bad], axis: 0)
    assert_equal [5, 4], v.shape
  end

  def test_combine_non_uniform_raises
    bad = CArray.float64(2, 4) { 999.0 }
    assert_raise(ArgumentError) {
      CArray.montage([@a, @b, bad, @d], [2, 2], axis: 0)
    }
  end

  def test_montage_tdim_size_mismatch_raises
    err = assert_raise(ArgumentError) {
      CArray.montage([@a, @b, @c, @d], [2, 3], axis: 0)   # 6 expected, 4 given
    }
    assert_match(/tdim product/, err.message)
  end

  # ------------ AC2.5: concat / mosaic eager + bit-exact with legacy ------------

  def test_concat_uniform_matches_bind
    eager_concat = CArray.concatenate([@a, @b, @c], axis: 0)
    via_bind     = CArray.meld([@a, @b, @c], axis: 0).to_ca
    assert_equal CArray, eager_concat.class
    assert_equal via_bind.to_a, eager_concat.to_a
  end

  def test_concat_ragged
    a100 = CArray.float64(100, 4) { |i, j| i * 1000 + j }
    a200 = CArray.float64(200, 4) { |i, j| 1_000_000 + i * 1000 + j }
    result = CArray.concatenate([a100, a200], axis: 0)
    assert_equal CArray, result.class
    assert_equal [300, 4], result.shape
    assert_equal 0.0,          result[0, 0]
    assert_equal 1_000_000.0,  result[100, 0]
  end

  def test_mosaic_ragged_2x2
    f1 = CArray.float64(2, 3) { 1.0 }
    f2 = CArray.float64(2, 5) { 2.0 }
    g1 = CArray.float64(4, 3) { 3.0 }
    g2 = CArray.float64(4, 5) { 4.0 }
    m = CArray.mosaic([f1, f2, g1, g2], [2, 2], axis: 0)
    assert_equal CArray, m.class
    assert_equal [6, 8], m.shape
    assert_equal 1.0, m[0, 0]
    assert_equal 2.0, m[0, 4]
    assert_equal 3.0, m[2, 0]
    assert_equal 4.0, m[2, 4]
  end

  def test_concat_rejects_non_tile_axis_mismatch
    # ragged is allowed only along the concat axis; a mismatch on a non-tile
    # axis must raise (previously silently clipped via paste).
    a = CArray.int32(3, 4) { 1 }
    b = CArray.int32(2, 5) { 2 }   # axis-1 size 5 != 4
    assert_raise(ArgumentError) { CArray.concatenate([a, b], axis: 0) }
  end

  def test_mosaic_rejects_inconsistent_block
    # a valid block matrix needs consistent row heights / column widths; an
    # inconsistent tile must raise rather than silently clip.
    f1 = CArray.float64(2, 3) { 1.0 }
    f2 = CArray.float64(2, 5) { 2.0 }
    g1 = CArray.float64(4, 3) { 3.0 }
    bad = CArray.float64(4, 9) { 4.0 }   # column 1 width 9 != 5
    assert_raise(ArgumentError) { CArray.mosaic([f1, f2, g1, bad], [2, 2], axis: 0) }
  end

  # ------------ AC2.6: data_type omitted → result_type auto-infer ------------

  def test_data_type_inferred_from_result_type
    # @a, @b, @c are all float64
    v = CArray.meld([@a, @b, @c], axis: 0)
    assert_equal "float64", v.data_type_name
  end

  # ------------ dtype semantics: strict view, cast is caller responsibility ------------

  def test_dtype_mismatch_raises
    a_int = CArray.int32(3, 4) { |i, j| i * 10 + j }
    a_f   = CArray.float64(3, 4) { |i, j| 100.0 + i * 10 + j }
    # CArray.meld is a view constructor: mismatched dtype raises.  For
    # auto-cast use CArray.concatenate (eager) or pre-cast pieces yourself
    # via .to_type.
    assert_raise(ArgumentError) { CArray.meld([a_int, a_f], axis: 0) }
  end

  def test_precast_then_meld_promotes
    a_int = CArray.int32(3, 4) { |i, j| i * 10 + j }
    a_f   = CArray.float64(3, 4) { |i, j| 100.0 + i * 10 + j }
    v = CArray.meld([a_int.to_type(:float64), a_f], axis: 0)
    assert_equal "float64", v.data_type_name
  end

  def test_concatenate_still_auto_casts
    a_int = CArray.int32(3, 4) { |i, j| i * 10 + j }
    a_f   = CArray.float64(3, 4) { |i, j| 100.0 + i * 10 + j }
    v = CArray.concatenate([a_int, a_f], axis: 0)
    assert_equal "float64", v.data_type_name
  end

  def test_concatenate_data_type_kwarg
    v = CArray.concatenate([@a, @b, @c], axis: 0, data_type: :float64)
    assert_equal "float64", v.data_type_name
  end

  # ------------ tabulate: assemble column blocks into a 2-D table ------------

  def test_tabulate_uniform_columns
    c1 = CA_INT([1, 2, 3]); c2 = CA_INT([4, 5, 6]); c3 = CA_INT([7, 8, 9])
    t = CArray.tabulate([c1, c2, c3])
    assert_equal CArray, t.class
    assert_equal [3, 3], t.shape
    assert_equal [[1, 4, 7], [2, 5, 8], [3, 6, 9]], t.to_a
  end

  def test_tabulate_rejects_ragged_length
    # tabulate does not pad: unequal length (row count) must raise (not
    # silently 0-fill the first column's length, nor truncate longer ones).
    assert_raise(ArgumentError) {
      CArray.tabulate([CA_INT([1, 2, 3]), CA_INT([4, 5])])
    }
    assert_raise(ArgumentError) {
      CArray.tabulate([CA_INT([1, 2]), CA_INT([4, 5, 6, 7])])
    }
  end

  def test_tabulate_ragged_column_counts
    # equal length L=3, but column counts 1 + 2 + 1 -> 4-column table.
    c1 = CA_INT([1, 2, 3])
    c2 = CA_INT([[4, 40], [5, 50], [6, 60]])
    c3 = CA_INT([7, 8, 9])
    t = CArray.tabulate([c1, c2, c3])
    assert_equal CArray, t.class
    assert_equal [3, 4], t.shape
    assert_equal [[1, 4, 40, 7], [2, 5, 50, 8], [3, 6, 60, 9]], t.to_a
  end

  def test_tabulate_promotes_data_type
    t = CArray.tabulate([CA_INT([1, 2, 3]), CA_DOUBLE([1.5, 2.5, 3.5])])
    assert_equal :float64, t.data_type
  end

  def test_tabulate_coerces_to_given_data_type
    t = CArray.tabulate([CA_INT([1, 2, 3]), CA_DOUBLE([1.5, 2.5, 3.5])],
                        data_type: :int32)
    assert_equal :int32, t.data_type
    assert_equal [[1, 1], [2, 2], [3, 3]], t.to_a
  end

  def test_tabulate_rejects_3d
    assert_raise(ArgumentError) {
      CArray.tabulate([CA_INT([[[1, 2], [3, 4]]])])
    }
  end

  # ------------ Partial-use ergonomic via view chain ------------

  def test_bind_view_supports_partial_use
    # AC3 (partial-use): view-default lets user slice before materialise
    big = (0...50).map { |k| CArray.float64(100) { |i| k * 1000 + i } }
    v = CArray.meld(big, axis: 0)              # view of shape (5000,)
    refute_equal CArray, v.class
    assert_equal [5000], v.shape
    # range index preserves ndim → partial-use path engages
    region = v[2000..2010].to_ca
    assert_equal [11], region.shape
    assert_equal 20_000.0, region[0]    # = k=20, i=0
  end

  # ------------ Empty list raises ------------

  def test_empty_list_raises_bind
    assert_raise(ArgumentError) { CArray.meld([], axis: 0) }
  end

  def test_empty_list_raises_merge
    assert_raise(ArgumentError) { CArray.stack([], axis: 0) }
  end

end
