require "test/unit"
require "carray"

# An operation that writes into an array while reading another array that
# lives in the same root reads the second array as it was before the
# operation: the answer equals the answer computed from a copy of it.
class TestWriteOverlappingInput < Test::Unit::TestCase

  def test_scatter_values_from_the_receiver
    [:scatter_add!, :scatter_sub!, :scatter_mul!, :scatter_replace!,
     :scatter_min!, :scatter_max!].each do |op|
      a = CArray.int64(10).seq!(1)
      e = CArray.int64(10).seq!(1)
      idx = CA_INT64((1..9).to_a)
      e.send(op, idx, e[0..8].copy)
      a.send(op, idx, a[0..8])
      assert_equal e.to_a, a.to_a, op.to_s
    end
  end

  def test_scatter_values_mask_from_the_receiver
    a = CArray.int64(10).seq!
    a[0] = UNDEF
    a.scatter_replace!(CA_INT64((1..9).to_a), a[0..8])
    assert_equal [true, true] + [false] * 8, a.is_masked.to_a
  end

  def test_scatter_addresses_from_the_receiver
    a = CArray.int64(10) { |i| (i + 1) % 10 }
    a.scatter_replace!(a, 0)
    assert_equal [0] * 10, a.to_a

    a = CA_INT64([2, 1, 0, 0, 0])
    a.scatter_add!(a[0..2], 10)
    assert_equal [12, 11, 10, 0, 0], a.to_a
  end

  def test_put_nd_with_masked_index_and_values_from_the_receiver
    a = CArray.int64(10).seq!
    idx = CA_INT64([[1], [2], [3], [5]])
    idx[3, 0] = UNDEF
    a.put_nd(idx, a[0..3])
    assert_equal [0, 0, 1, 2, 4, 5], a.to_a[0, 6]
  end

  def masked_seq (n, *undef_at)
    a = CArray.int32(n).seq!
    undef_at.each { |i| a[i] = UNDEF }
    a
  end

  def test_inherit_mask_from_a_shifted_view
    [1, 8, 16].each do |k|
      a = masked_seq(1000, 0, 7)
      a[k..].inherit_mask(a[0...(1000 - k)])
      expected = [0, 7, k, 7 + k].uniq.sort
      assert_equal expected, (0...1000).select { |i| a.is_masked[i] }, "shift #{k}"
    end
  end

  def test_inherit_mask_replace_from_itself_and_a_shifted_view
    a = masked_seq(10, 0, 7)
    a.inherit_mask_replace(a)
    assert_equal [0, 7], (0...10).select { |i| a.is_masked[i] }

    a = masked_seq(1000, 0, 7)
    a[8..].inherit_mask_replace(a[0..991])
    assert_equal [0, 7, 8, 15], (0...1000).select { |i| a.is_masked[i] }
  end

  def test_mask_assigned_from_the_receivers_root
    b = CArray.boolean(1000)
    b[0] = 1
    b[7] = 1
    b[8..].mask = b[0..991]
    assert_equal [8, 15], (0...1000).select { |i| b.is_masked[i] }

    b = CArray.boolean(1000)
    b[0] = UNDEF
    b[7] = UNDEF
    b[8..].mask = b[0..991]
    assert_equal [0, 7, 8, 15], (0...1000).select { |i| b.is_masked[i] }
  end

end

# The C author surface: the sweep engine and the kernel iterator's paired
# walks, through the dev-build fixtures.
class TestWriteOverlappingInputAuthorSurface < Test::Unit::TestCase

  def self.load_fixture (dir, lib)
    ext_dir = File.expand_path(dir, __dir__)
    $LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
    require lib
    true
  rescue LoadError
    false
  end

  SWEEP = load_fixture("ext_sweep_raw", "sweep_raw")
  ITER  = load_fixture("ext_iter_write", "iter_write")

  def sweep_case (m, n)
    x = CArray.float64(n).seq!
    e = CArray.float64(n).seq!
    CArray.send(m, e[1..], e[0..n-2].copy, CArray.float64(n - 1))
    CArray.send(m, x[1..], x[0..n-2], CArray.float64(n - 1))
    assert_equal e.to_a, x.to_a, "#{m} shift n=#{n}"

    x = CArray.float64(n).seq!
    e = CArray.float64(n).seq!
    CArray.send(m, e, e.reverse.copy, CArray.float64(n))
    CArray.send(m, x, x.reverse, CArray.float64(n))
    assert_equal e.to_a, x.to_a, "#{m} reverse n=#{n}"
  end

  def test_sweep_input_from_the_outputs_root
    omit "sweep_raw fixture not built" unless SWEEP
    [:__sweep_raw_add__, :__sweep_raw_add_slab__].each do |m|
      [10, 200_000].each { |n| sweep_case(m, n) }
    end
  end

  def test_iterator_inout_input_from_the_outputs_root
    omit "iter_write fixture not built" unless ITER
    [[5, 4], [500, 400]].each do |r, c|
      x = CArray.float64(r, c).seq!
      e = CArray.float64(r, c).seq!
      e[1..r-1, nil] = e[0..r-2, nil].copy
      CArray.iw_inout_copy(x[0..r-2, nil], x[1..r-1, nil], 1)
      assert_equal e.to_a, x.to_a, "row shift #{r}x#{c}"
    end

    x = CArray.float64(5, 5).seq!
    e = x.transpose.copy
    CArray.iw_inout_copy(x.transpose, x, 1)
    assert_equal e.to_a, x.to_a, "transpose"
  end

  # A view with several parents (stack, meld) reaches the root through
  # each parent, on either side of the walk.
  def test_iterator_inout_through_a_multi_parent_view
    omit "iter_write fixture not built" unless ITER
    swapped = ->(r) { CArray.stack([r[1, nil], r[0, nil]]) }
    melded  = ->(r) { CArray.meld(r[1..1, nil], r[0..0, nil], axis: 0) }
    [swapped, melded].each_with_index do |build, i|
      x = CA_FLOAT64([[1, 2, 3], [4, 5, 6]])
      CArray.iw_inout_copy(build.(x), x, 1)
      assert_equal [[4, 5, 6], [1, 2, 3]], x.to_a, "input view #{i}"

      x = CA_FLOAT64([[1, 2, 3], [4, 5, 6]])
      CArray.iw_inout_copy(x, build.(x), 1)
      assert_equal [[4, 5, 6], [1, 2, 3]], x.to_a, "output view #{i}"
    end
  end

end
