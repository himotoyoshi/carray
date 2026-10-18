$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# Hand-written kernels that move or read cells keep the mask with them.

class TestProjectFillUndef < Test::Unit::TestCase

  # A fill of UNDEF is no fill: the out-of-range cell is masked, as it is
  # when no fill is given, and as `strip_mask(UNDEF)` and a store keep it.
  def test_undef_fill_masks
    a = CA_INT32([10, 20, 30])
    idx = CA_INT64([0, -1, 9])
    assert_equal [10, UNDEF, UNDEF], a.project(idx, UNDEF).to_a
    assert_equal a.project(idx).to_a, a.project(idx, UNDEF).to_a
  end

  def test_undef_on_one_side_only
    a = CA_INT32([10, 20, 30])
    idx = CA_INT64([0, -1, 9])
    assert_equal [10, UNDEF, 7], a.project(idx, UNDEF, 7).to_a
    assert_equal [10, 5, UNDEF], a.project(idx, 5, UNDEF).to_a
  end

end

class TestCountMaskedQueryCell < Test::Unit::TestCase

  # A masked cell of a query array asks nothing; its count is masked
  # rather than the count of self's masked cells.
  def test_masked_query_cell_gives_masked_count
    m = CA_INT32([UNDEF, 1, 2])
    assert_equal [1, UNDEF], m.count(CA_INT32([1, UNDEF])).to_a
  end

  def test_per_axis
    a = CArray.int32(2, 3).seq
    q = CA_INT32([1, UNDEF])
    assert_equal [[1, UNDEF], [0, UNDEF]], a.count(q, axis: 1).to_a
  end

end

class TestShuffleMovesTheMask < Test::Unit::TestCase

  def check (a, **kw)
    values = a.value.copy
    masked = a.is_masked.copy
    a.shuffle!(**kw, rng: Random.new(7))
    # Every masked cell still hides its own value: the pairs (value, mask)
    # are a permutation of the pairs before.
    before = values.to_a.flatten.zip(masked.to_a.flatten).sort_by(&:to_s)
    after  = a.value.to_a.flatten.zip(a.is_masked.to_a.flatten).sort_by(&:to_s)
    assert_equal before, after
  end

  def test_all_cells
    a = CArray.int32(8).seq
    a[[1, 4]] = UNDEF
    check(a)
  end

  def test_along_an_axis
    a = CArray.int32(3, 4).seq
    a[0, 1] = UNDEF
    a[2, 3] = UNDEF
    check(a, axis: 1)
    check(a, axis: 0)
  end

  def test_view
    r = CArray.int32(8).seq
    r[3] = UNDEF
    check(r[2..5])
    assert_equal 1, r.count_masked
  end

  def test_copy_form
    a = CArray.int32(6).seq
    a[2] = UNDEF
    s = a.shuffle(rng: Random.new(3))
    assert_equal [2], s.value[s.is_masked].to_a
    assert_equal [UNDEF], a[2..2].to_a
  end

end

class TestPutWithMaskedIndices < Test::Unit::TestCase

  # With a masked index the unmasked cells are written exactly as they are
  # when no index is masked; the masked index writes nothing.
  def check (values)
    idx = CA_INT64([[2], [0]])
    plain = CArray.int32(2, 3).seq
    plain.put_along_axis(idx, values, axis: 1)
    midx = idx.copy
    midx[1, 0] = UNDEF
    a = CArray.int32(2, 3).seq
    a.put_along_axis(midx, values, axis: 1)
    assert_equal plain[0, nil].to_a, a[0, nil].to_a, values.inspect
    assert_equal [3, 4, 5], a[1, nil].to_a, values.inspect
  end

  def test_values_mean_what_they_mean_unmasked
    check(99)
    check(UNDEF)
    check(CA_INT32([[7], [8]]))
    check([7, 8])
  end

  def test_a_face
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D).reshape(1, 3)
    i = CA_INT64([[2, 0]])
    i[0, 1] = UNDEF
    t.put_along_axis(i, t[0, 0], axis: 1)
    assert_equal %w[2024-01-01 2024-01-02 2024-01-01], t.to_a.flatten.map(&:to_s)
  end

  def test_put_nd_converts_as_the_store
    x = CArray.int8(3).seq
    q = CA_INT64([[0], [2]])
    q[1, 0] = UNDEF
    assert_raise(RangeError) { x.put_nd(q, 300) }
    x.put_nd(q, CA_INT8([7, 8]))
    assert_equal [7, 1, 2], x.to_a
  end

  def test_put_nd_on_a_frozen_array
    x = CArray.int8(2).seq.freeze
    assert_raise(FrozenError) { x.put_nd(CA_INT64([[0]]), 1) }
  end

end

class TestRandomFillClearsTheMask < Test::Unit::TestCase

  # Every cell gets a value, as with seq! and fill.
  def test_random_and_randomn
    m = CA_INT32([1, UNDEF, 3])
    m.random!(10)
    assert_equal 0, m.count_masked
    f = CA_FLOAT64([1, UNDEF, 3])
    f.randomn!
    assert_equal 0, f.count_masked
  end

  def test_through_a_view
    r = CA_FLOAT64([1, UNDEF, 3, UNDEF])
    r[0..1].random!
    assert_equal [false, false, false, true], r.is_masked.to_a
  end

end
