# frozen_string_literal: true
#
# SO.6+ — `sort_copy(axis:)` and `partition_copy(kth, axis:)` eager
# counterparts (PROPOSAL_SORT_AXIS rev9).
#
# Pins:
#   - sort_copy returns fresh entity CArray (= not CARemap view)
#   - shape and data_type preserved
#   - byte parity with `sort(axis:).to_ca`
#   - no-arg form flattens (= 1-D output, same as `sort.to_ca`)
#   - negative axis
#   - all ALL_NUMERIC data_types (i8..u64, f32, f64)
#   - mask: actually-masked raises; mask-field-only strips
#   - CA_FIXLEN falls back to eager flat-sort copy (matches sort path)
#   - partition_copy: kth position correct, before <=, after >=
#   - partition_copy: negative kth
#   - partition_copy: out-of-range kth raises
#   - in-place idiom `a[] = a.sort_copy(axis: k)` works

require "test/unit"
require "carray"

class TestSortCopy < Test::Unit::TestCase

  # ---- sort_copy basic --------------------------------------------------

  def test_returns_fresh_entity_carray
    data = [[3, 1, 4, 1, 5], [9, 2, 6, 5, 3]]
    a = CArray.int32(2, 5) { |i, j| data[i][j] }
    s = a.sort_copy(axis: 1)
    # Eager entity, not a CARemap view (= main contrast with `sort`).
    assert_equal CArray, s.class
    assert_equal [2, 5], s.dim
    assert_equal CA_INT32, s.data_type
  end

  def test_byte_parity_with_sort_axis_to_ca
    data = [[3, 1, 4, 1, 5, 9], [2, 6, 5, 3, 5, 8], [9, 7, 9, 3, 2, 3]]
    a = CArray.int32(3, 6) { |i, j| data[i][j] }

    [0, 1, -1].each do |k|
      s_copy = a.sort_copy(axis: k)
      s_view = a.sort(axis: k).to_ca
      assert_equal s_view.to_a, s_copy.to_a, "axis=#{k} parity mismatch"
    end
  end

  def test_no_arg_flatten
    a = CArray.int32(2, 3) { |i, j| [[3, 1, 4], [1, 5, 9]][i][j] }
    s = a.sort_copy
    assert_equal [6], s.dim                              # flattened
    assert_equal [1, 1, 3, 4, 5, 9], s.to_a
    # Should match `sort.to_ca` (no-arg) for 1-D parity.
    assert_equal a.sort.to_ca.to_a, s.to_a
  end

  def test_all_numeric_data_types
    src = [3, 1, 4, 1, 5, 9, 2, 6]
    expected = src.sort
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
       float32 float64].each do |dt|
      a = CArray.send(dt, src.size) { |i| src[i] }
      s = a.sort_copy
      got = s.to_a
      got = got.map(&:to_i) if dt.to_s.start_with?("float")
      assert_equal expected, got, "#{dt} sort_copy failed"
    end
  end

  def test_negative_axis
    a = CArray.int32(3, 4) { |i, j| (i + j * 3) % 5 }
    s1 = a.sort_copy(axis: 1)
    sneg = a.sort_copy(axis: -1)
    assert_equal s1.to_a, sneg.to_a
  end

  def test_axis_out_of_range_raises
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a.sort_copy(axis: 2) }
    assert_raise(ArgumentError) { a.sort_copy(axis: -3) }
  end

  # ---- sort_copy mask semantics -----------------------------------------

  def test_masked_input_sorts_to_masked_position
    a = CArray.int32(5) { |i| [3, 1, 4, 1, 5][i] }
    a[2] = UNDEF                                # [3, 1, UNDEF, 1, 5]
    s = a.sort_copy
    assert_equal([1, 1, 3, 5, UNDEF], s.to_a)
    assert_equal([false, false, false, false, true], s.mask.to_a)

    s_first = a.sort_copy(masked_position: :first)
    assert_equal([UNDEF, 1, 1, 3, 5], s_first.to_a)
    assert_equal([true, false, false, false, false], s_first.mask.to_a)
  end

  def test_mask_field_but_no_actually_masked_strips
    # `a[:is_not_masked].sort_copy` is the canonical Ruby idiom — the
    # view has a mask field inherited from `a` even when no cells are
    # actually masked.
    a = CArray.int32(5) { |i| [3, 1, 4, 1, 5][i] }
    view = a[:is_not_masked]                      # mask-field-set view
    refute a.has_mask?, "fresh entity should not have mask field"
    s = view.sort_copy
    assert_equal [1, 1, 3, 4, 5], s.to_a
  end

  # ---- sort_copy CA_FIXLEN (unified onto the sort_addr_ki dialect) ------

  def test_fixlen_sort_copy_flat
    # CA_FIXLEN sort_copy materializes the `sort` view (sort_addr_ki fixlen
    # dialect): no-axis flattens to a 1-D eager entity, like numeric.
    a = CArray.fixlen(3, bytes: 2) { |i| ["b", "a", "c"][i] }
    s = a.sort_copy
    assert_equal CArray, s.class
    assert_equal ["a\x00", "b\x00", "c\x00"], s.to_a
    assert_equal [3], s.shape       # 1-D already, flatten is a no-op here
  end

  def test_fixlen_sort_copy_axis_sorts_per_fiber
    # Regression: the old eager flat fallback ignored axis: and returned a
    # flat-sorted reshape.  sort_copy(axis:) now sorts each fiber.
    a = CArray.fixlen(2, 2, bytes: 3) { |i, j| %w[cat ant dog bee][i * 2 + j] }
    s = a.sort_copy(axis: 1)
    assert_equal CArray, s.class
    assert_equal [["ant", "cat"], ["bee", "dog"]], s.to_a
  end

  # ---- in-place idiom ---------------------------------------------------

  def test_in_place_via_assignment
    # `a[] = a.sort_copy(axis: k)` recovers in-place sort (= view-counter-
    # part bang policy, CLAUDE.md「設計の前提: bang 兄弟廃止」).
    data = [[3, 1, 4], [9, 2, 6]]
    a = CArray.int32(2, 3) { |i, j| data[i][j] }
    a[] = a.sort_copy(axis: 1)
    assert_equal [[1, 3, 4], [2, 6, 9]], a.to_a
  end
end


class TestPartitionCopy < Test::Unit::TestCase

  def test_returns_fresh_entity_carray
    a = CArray.int32(3, 5) { |i, j| (i + 2 * j) % 7 }
    p = a.partition_copy(2, axis: 1)
    assert_equal CArray, p.class
    assert_equal a.dim, p.dim
    assert_equal a.data_type, p.data_type
  end

  def test_kth_position_correct_and_split
    data = [[3, 1, 4, 1, 5, 9, 2, 6], [8, 7, 5, 3, 2, 3, 0, 1]]
    a = CArray.int32(2, 8) { |i, j| data[i][j] }
    [0, 2, 4, 7].each do |kth|
      p = a.partition_copy(kth, axis: 1)
      2.times do |i|
        sorted = data[i].sort
        row = p.to_a[i]
        assert_equal sorted[kth], row[kth],
                     "row #{i} kth=#{kth}: position wrong"
        assert row[0...kth].all? { |v| v <= sorted[kth] },
               "row #{i} kth=#{kth}: before contains > pivot"
        assert row[(kth + 1)..].all? { |v| v >= sorted[kth] },
               "row #{i} kth=#{kth}: after contains < pivot"
      end
    end
  end

  def test_negative_kth
    data = [3, 1, 4, 1, 5, 9, 2, 6]
    a = CArray.int32(8) { |i| data[i] }
    p = a.partition_copy(-1)
    sorted = data.sort
    assert_equal sorted[-1], p.to_a[-1]
  end

  def test_kth_out_of_range_raises
    a = CArray.int32(5).seq
    assert_raise(ArgumentError) { a.partition_copy(5) }
    assert_raise(ArgumentError) { a.partition_copy(-6) }
  end

  def test_default_axis_is_zero
    a = CArray.int32(3, 4) { |i, j| (j * 3 + i) % 7 }
    p_default = a.partition_copy(1)
    p_axis0 = a.partition_copy(1, axis: 0)
    assert_equal p_axis0.to_a, p_default.to_a
  end

  def test_all_numeric_dtypes_kth
    src = [3, 1, 4, 1, 5, 9, 2, 6]
    sorted_kth = src.sort[3]
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
       float32 float64].each do |dt|
      a = CArray.send(dt, src.size) { |i| src[i] }
      p = a.partition_copy(3)
      got = p.to_a[3]
      got = got.to_i if dt.to_s.start_with?("float")
      assert_equal sorted_kth, got, "#{dt} partition_copy kth wrong"
    end
  end

  def test_masked_input_clusters_to_masked_position
    a = CArray.int32(5).seq
    a[2] = UNDEF                                # [0, 1, UNDEF, 3, 4]
    p_last = a.partition_copy(2)                # valid slice [0,1,3,4] kth=2 -> 3
    assert_equal([0, 1, 3, 4, UNDEF], p_last.to_a)
    assert_equal([false, false, false, false, true], p_last.mask.to_a)

    p_first = a.partition_copy(2, masked_position: :first)
    assert_equal([UNDEF, 0, 1, 3, 4], p_first.to_a)
    assert_equal([true, false, false, false, false], p_first.mask.to_a)
  end

  # CA_FIXLEN partition_copy is supported as of the fixlen sort-family
  # dialect (3.0): per-fiber quickselect via ca_quickselect_bytes with
  # raw memcmp ordering.  kth=0 holds the smallest element.
  def test_fixlen_partition_copy_supported
    a = CArray.fixlen(3, bytes: 2) { |i| ["b", "a", "c"][i] }
    part = a.partition_copy(0)
    assert_equal(a.sort_copy[0], part[0])
  end
end
