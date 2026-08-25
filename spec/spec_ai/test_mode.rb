# Test for CArray#is_mode (first-class primitive) and CArray#mode (value
# consumer), the frequency-table members of the value-hash discovery family.
#
# Contract (PROPOSAL_MODE_REDUCTION):
#   - is_mode returns a shape-preserving boolean: true at every occurrence of
#     every most-frequent value (ties all marked, never broken).
#   - axis: nil = whole array; axis: k = per fiber.
#   - Masked cells excluded and false; empty / all-masked fiber all false (no
#     identity, no raise).
#   - Numeric NaN-collapse / -0.0==+0.0 distinctness (family); object/fixlen via
#     Ruby eql?/hash.
#   - mode returns the distinct modal values ascending (flat only for now;
#     mode(axis:) raises NotImplementedError).

require "test/unit"
require "carray"

class TestMode < Test::Unit::TestCase

  # ---- is_mode ----------------------------------------------------------

  def test_is_mode_ties_all_marked
    assert_equal [true, true, true, true, false], CA_INT32([1, 1, 2, 2, 3]).is_mode.to_a
  end

  def test_is_mode_single_mode
    assert_equal [true, true, true, false, false], CA_INT32([5, 5, 5, 1, 2]).is_mode.to_a
  end

  def test_is_mode_all_unique_all_modal
    assert_equal [true, true, true], CA_INT32([7, 8, 9]).is_mode.to_a
  end

  def test_is_mode_is_boolean
    assert_equal CA_BOOLEAN, CA_INT32([1, 1, 2]).is_mode.data_type
  end

  def test_is_mode_per_axis
    a = CA_INT32([[1, 1, 2], [3, 4, 4]])
    assert_equal [[true, true, false], [false, true, true]], a.is_mode(axis: 1).to_a
  end

  def test_is_mode_per_axis_0
    a = CA_INT32([[1, 2], [1, 3], [4, 2]])
    # col0: 1,1,4 -> 1 modal at rows 0,1; col1: 2,3,2 -> 2 modal at rows 0,2
    assert_equal [[true, true], [true, false], [false, true]], a.is_mode(axis: 0).to_a
  end

  def test_is_mode_masked_excluded
    b = CA_INT32([2, 2, 3, 3, 3]); b[0] = UNDEF; b.mask = [1, 0, 0, 0, 0]
    # value 2 now count 1, value 3 count 3 -> only the 3s are modal
    assert_equal [false, false, true, true, true], b.is_mode.to_a
  end

  def test_is_mode_all_masked_all_false
    c = CA_INT32([1, 2]); c.mask = [1, 1]
    assert_equal [false, false], c.is_mode.to_a
  end

  def test_is_mode_float_nan_collapse
    nan = Float::NAN
    assert_equal [true, true, false], CA_FLOAT64([nan, nan, 1.0]).is_mode.to_a
  end

  def test_is_mode_object
    o = CA_OBJECT([:a, :a, :b, :c, :c])
    assert_equal [true, true, false, true, true], o.is_mode.to_a  # a,c tie
  end

  def test_is_mode_object_per_axis
    o = CA_OBJECT([[:a, :a, :b], [:c, :d, :d]])
    assert_equal [[true, true, false], [false, true, true]], o.is_mode(axis: 1).to_a
  end

  def test_is_mode_object_masked
    o = CA_OBJECT([:a, :a, :b]); o[0] = UNDEF
    # a now count 1, b count 1 -> both modal (max count 1), masked cell false
    assert_equal [false, true, true], o.is_mode.to_a
  end

  def test_is_mode_selects_modal_cells
    a = CA_INT32([1, 1, 2, 2, 3])
    assert_equal [1, 1, 2, 2], a[a.is_mode].to_a
  end

  # ---- mode -------------------------------------------------------------

  def test_mode_flat_ties
    assert_equal [1, 2], CA_INT32([1, 1, 2, 2, 3]).mode.to_a  # ascending, both modes
  end

  def test_mode_flat_single
    assert_equal [5], CA_INT32([5, 5, 5, 1, 2]).mode.to_a
  end

  def test_mode_same_dtype
    assert_equal CA_INT32, CA_INT32([1, 1, 2]).mode.data_type
  end

  def test_mode_masked
    b = CA_INT32([2, 2, 3, 3, 3]); b[0] = UNDEF; b.mask = [1, 0, 0, 0, 0]
    assert_equal [3], b.mode.to_a
  end

  def test_mode_all_masked_empty
    e = CA_FLOAT64([1.0]); e.mask = [1]
    assert_equal [], e.mode.to_a
    assert_equal 0, e.mode.size
  end

  def test_mode_float_nan_collapse
    nan = Float::NAN
    assert_equal [1.0], CA_FLOAT64([nan, nan, 1.0, 1.0, 1.0]).mode.to_a
  end

  def test_mode_object
    assert_equal [:a, :c], CA_OBJECT([:a, :a, :b, :c, :c]).mode.to_a
    assert_equal CA_OBJECT, CA_OBJECT([:a]).mode.data_type
  end

  def test_mode_fixlen
    f = CArray.new(CA_FIXLEN, [5], bytes: 2) { |i| ["x", "x", "y", "z", "z"][i] }
    assert_equal ["x", "z"], f.mode.to_a.map { |s| s.delete("\x00") }
    assert_equal CA_FIXLEN, f.mode.data_type
  end

  def test_mode_multidim_flattens
    assert_equal [1, 2], CA_INT32([[1, 1], [2, 2]]).mode.to_a
  end

  # ---- per-axis mode (F: Array<CArray>, quantile-style) -----------------

  def test_mode_per_axis_array_of_carrays
    m = CA_INT32([[1, 1, 2, 2, 3], [4, 4, 4, 5, 6], [7, 7, 8, 8, 9]])
    res = m.mode(axis: 1)
    assert_equal Array, res.class
    assert_equal 2, res.size                 # K = widest fiber's mode count
    assert_equal [1, 4, 7], res[0].to_a      # smallest mode per fiber
    assert_equal [2, UNDEF, 8], res[1].to_a  # 2nd mode, single-mode fiber masked
  end

  def test_mode_per_axis_stack_gives_padded_form
    m = CA_INT32([[1, 1, 2, 2, 3], [4, 4, 4, 5, 6], [7, 7, 8, 8, 9]])
    a = CArray.stack(m.mode(axis: 1), axis: 1)
    assert_equal [3, 2], a.shape
    assert_equal [[1, 2], [4, UNDEF], [7, 8]], a.to_a
    assert_equal [[false, false], [false, true], [false, false]], a.mask.to_a
  end

  def test_mode_per_axis_3d
    t = CA_INT32([[[1, 1, 2], [3, 3, 3]], [[4, 5, 6], [7, 7, 8]]])  # (2,2,3)
    res = t.mode(axis: 2)
    assert_equal 3, res.size                                  # [4,5,6] is all-unique
    assert_equal [2, 2], res[0].shape
    assert_equal [[1, 3], [4, 7]], res[0].to_a
    assert_equal [[UNDEF, UNDEF], [5, UNDEF]], res[1].to_a
  end

  def test_mode_per_axis_masked_fiber
    mm = CA_INT32([[2, 2, 3], [1, 1, 1]])
    mm[0, 0] = UNDEF; mm[0, 1] = UNDEF; mm[0, 2] = UNDEF
    mm.mask = [[1, 1, 1], [0, 0, 0]]
    assert_equal [UNDEF, 1], mm.mode(axis: 1)[0].to_a        # empty fiber -> UNDEF
  end

  def test_mode_per_axis_all_masked_empty_array
    am = CA_INT32([[1, 2], [3, 4]]); am.mask = [[1, 1], [1, 1]]
    assert_equal [], am.mode(axis: 1)                         # no modes anywhere
  end

  def test_mode_axis_object
    o = CA_OBJECT([[:a, :a, :b], [:c, :d, :d]])
    res = o.mode(axis: 1)
    assert_equal [:a, :d], res[0].to_a
  end

  def test_mode_1d_axis0_scalars
    # 1-D input reduced along axis 0: like flat quantile, an Array of scalars.
    assert_equal [1, 2], CA_INT32([1, 1, 2, 2, 3]).mode(axis: 0)
  end

  # ---- differential: C kernel == independent Ruby recomputation ---------

  # Recompute mode(axis: k) from scratch in plain Ruby (per-fiber tally), as an
  # oracle independent of the C kernel and of the shipped Ruby object path.
  def ruby_mode_axis (a, k)
    src   = a.to_a
    shape = a.shape
    outer = shape.dup; outer.delete_at(k)
    coords = outer.empty? ? [[]] : outer.map { |n| (0...n).to_a }
                                         .inject([[]]) { |acc, dim| acc.product(dim.map { |x| [x] }).map(&:flatten) }
    lists = coords.map do |co|
      vals = (0...shape[k]).map do |t|
        idx = co.dup.insert(k, t)
        idx.inject(src) { |cur, i| cur[i] }
      end
      tally = Hash.new(0)
      vals.each { |v| tally[v] += 1 }
      mx = tally.values.max
      tally.select { |_, c| c == mx }.keys.sort
    end
    kk = lists.map(&:size).max || 0
    (0...kk).map { |j| lists.map { |l| j < l.size ? l[j] : :UNDEF } }
  end

  def cols_to_oracle (cols)
    cols.map do |col|
      flat = col.respond_to?(:to_a) ? col.reshape(col.elements).to_a : [col]
      msk  = col.respond_to?(:mask) ? col.reshape(col.elements).mask.to_a : [false]
      flat.each_index.map { |i| msk[i] ? :UNDEF : flat[i] }
    end
  end

  def test_mode_axis_differential_random
    seed = 12345
    [[100, 30, 5], [30, 100, 5], [200, 4, 8], [5, 7, 3]].each do |n0, n1, kv|
      rng = Random.new(seed += 1)
      a = CArray.int32(n0, n1) { |i, j| rng.rand(kv) }
      [0, 1].each do |k|
        got = cols_to_oracle(a.mode(axis: k))
        want = ruby_mode_axis(a, k)
        assert_equal want, got, "shape #{[n0, n1]} axis #{k}"
      end
    end
  end

  def test_mode_axis_differential_3d
    rng = Random.new(999)
    a = CArray.int32(6, 5, 4) { |i, j, l| rng.rand(3) }
    [0, 1, 2].each do |k|
      got = cols_to_oracle(a.mode(axis: k))
      want = ruby_mode_axis(a, k)
      assert_equal want, got, "3d axis #{k}"
    end
  end

end
