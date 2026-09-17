# CAConstString's ordering family must answer on the strings, not on the
# offsets that hold them.
#
# A storage cell is a (start, end) byte range into the shared buffer, so
# storage order is the order the strings were packed in.  Only sort / min /
# max were overridden to read the bytes; every other member of the family
# descended to the offsets and came back well-formed and wrong --
# %w[pear apple fig kiwi].sort_addr gave the identity permutation,
# rank_index and order gave it too, min_index named the wrong cell, and
# partition_copy handed back NUL bytes.  None of them raised.
#
# The reference is the same column through #to_string, where a cell IS the
# string and CArray's own kernels apply: the two must agree everywhere.

require 'test/unit'
require 'carray'

class TestCAConstStringOrdering < Test::Unit::TestCase

  W = %w[pear apple fig kiwi].freeze

  def setup
    @cs = CArray.const_string(W).reshape(2, 2)
    @st = @cs.to_string
  end

  def value (r)
    r.is_a?(CArray) ? r.to_a : r
  end

  # ---------------- answers, spelled out ----------------

  def test_extrema
    assert_equal "apple", @cs.min
    assert_equal "pear",  @cs.max
    assert_equal ["apple", "pear"], @cs.minmax
    assert_equal 1, @cs.min_index
    assert_equal 0, @cs.max_index
  end

  def test_extrema_along_an_axis
    assert_equal ["apple", "fig"],  @cs.min(axis: 1).to_a
    assert_equal ["pear", "kiwi"],  @cs.max(axis: 1).to_a
    assert_equal ["fig", "apple"],  @cs.min(axis: 0).to_a
    assert_equal [1, 0], @cs.min_index(axis: 1).to_a
  end

  def test_sort_flattens_without_an_axis
    assert_equal ["apple", "fig", "kiwi", "pear"], @cs.sort.to_a
    assert_equal [4], @cs.sort.shape
  end

  def test_sort_along_an_axis_keeps_the_shape
    assert_equal [["apple", "pear"], ["fig", "kiwi"]], @cs.sort(axis: 1).to_a
    assert_equal [["fig", "apple"], ["pear", "kiwi"]], @cs.sort(axis: 0).to_a
  end

  def test_addresses_and_indices
    assert_equal [[1, 2], [3, 0]], @cs.sort_addr.to_a
    assert_equal [[1, 0], [0, 1]], @cs.sort_index.to_a
    assert_equal [[1, 0], [0, 1]], @cs.rank_index.to_a
    assert_equal [[3, 0], [1, 2]], @cs.order.to_a
  end

  def test_partition
    assert_equal [["fig", "apple"], ["pear", "kiwi"]], @cs.partition_copy(1).to_a
    assert_equal [[1, 0], [0, 1]], @cs.partition_index(1).to_a
  end

  # ---------------- and the same as reading the strings ----------------

  MEMBERS = {
    "min"                => ->(a) { a.min },
    "max"                => ->(a) { a.max },
    "minmax"             => ->(a) { a.minmax },
    "min(axis: 0)"       => ->(a) { a.min(axis: 0) },
    "max(axis: 1)"       => ->(a) { a.max(axis: 1) },
    "min_index"          => ->(a) { a.min_index },
    "max_index(axis: 1)" => ->(a) { a.max_index(axis: 1) },
    "sort"               => ->(a) { a.sort },
    "sort(axis: 0)"      => ->(a) { a.sort(axis: 0) },
    "sort(axis: 1)"      => ->(a) { a.sort(axis: 1) },
    # sort_copy is not in the reference list: CArray#sort_copy has no object
    # kernel, so CAString raises where CAConstString (sort + copy) answers.
    "sort_addr"          => ->(a) { a.sort_addr },
    "sort_addr(axis: 1)" => ->(a) { a.sort_addr(axis: 1) },
    "sort_index"         => ->(a) { a.sort_index },
    "sort_index(axis:1)" => ->(a) { a.sort_index(axis: 1) },
    "rank_index"         => ->(a) { a.rank_index },
    "order"              => ->(a) { a.order },
    "partition_copy(1)"  => ->(a) { a.partition_copy(1) },
    "partition_index(1)" => ->(a) { a.partition_index(1) },
  }.freeze

  def test_every_member_agrees_with_reading_the_strings
    MEMBERS.each do |name, f|
      want = value(f.call(@st))
      got  = value(f.call(@cs))
      assert_equal want, got, "#{name} disagrees with the same column as strings"
    end
  end

  def test_sort_copy_owns_its_bytes
    r = @cs.sort_copy
    assert_equal ["apple", "fig", "kiwi", "pear"], r.to_a
    assert_not_same @cs.buffer, r.buffer
  end

  def test_string_valued_results_come_back_as_a_const_string
    %w[min max].each do |m|
      assert_kind_of CAConstString, @cs.send(m, axis: 1)
    end
    [@cs.sort, @cs.sort(axis: 1), @cs.sort_copy, @cs.partition_copy(1)].each do |r|
      assert_kind_of CAConstString, r
    end
  end

  def test_sorting_gathers_rather_than_rebuilding
    assert_same @cs.buffer, @cs.sort.buffer
    assert_same @cs.buffer, @cs.sort(axis: 1).buffer
  end

  # ---------------- masked and empty ----------------

  def test_masked_cells_cluster_at_one_end
    ct = CArray.const_string(["b", nil, "c"])
    assert_equal ["b", "c", UNDEF], ct.sort.to_a
    assert_equal [UNDEF, "b", "c"], ct.sort(masked_position: :first).to_a
    assert_equal [0, 2, 1], ct.sort_addr.to_a
  end

  def test_extrema_skip_masked_cells
    ct = CArray.const_string(["b", "a", nil])
    assert_equal "a", ct.min
    assert_equal "b", ct.max
  end

  def test_nothing_to_compare_gives_undef
    assert_equal UNDEF, CArray.const_string([nil, nil]).min
    assert_equal UNDEF, CArray.const_string([]).max
  end

  # ---------------- the column's own encoding ----------------

  def test_results_keep_the_column_encoding
    sj = CArray.const_string(%w[い あ].map { |s| s.encode("Shift_JIS") },
                             encoding: Encoding::Shift_JIS)
    assert_equal ["あ", "い"], sj.sort.to_a.map { |s| s.encode("UTF-8") }
    assert_equal Encoding::Shift_JIS, sj.min(axis: 0).encoding
    # The discovery family rebuilds a column too, and lost the encoding the
    # same way: this used to raise out of the builder's encoding check.
    assert_equal ["い", "あ"], sj.unique.to_a.map { |s| s.encode("UTF-8") }
    assert_equal Encoding::Shift_JIS, sj.mask_duplicates.encoding
  end

  def test_an_n_dimensional_result_keeps_its_shape
    assert_equal [2, 2], @cs.to_string.to_const_string.shape
    assert_equal [2, 2], @cs.partition_copy(1).shape
  end

end
