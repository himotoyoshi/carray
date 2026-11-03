# frozen_string_literal: true
#
# What the family answers over a Face, a fill value or a classifier the route
# of a member was not first written for, against the core's answer.

require "test/unit"
require "carray"

class TestIteratorFamilyDoors < Test::Unit::TestCase
  Rec = CArray.struct(order_by: [:a]) { int32 :a; int32 :b }

  def seconds (*v)
    CA_INT64(v).timedelta(unit: :s)
  end

  def days (*v)
    CA_INT64(v).time(unit: :D)
  end

  def texts (a)
    a.to_a.flatten.map(&:to_s)
  end

  def record (*v)
    r = CARecord.new(Rec, v.size)
    r["a"][] = CA_INT32(v)
    r["b"][] = 0
    r
  end

  def tiles (it)
    r = []
    it.each { |t| r << t.to_a.map { |x| UNDEF.equal?(x) ? x : x.to_s } }
    r
  end

  # ---- a partial tile of a Face that cannot be written ------------------

  def test_each_over_a_partial_tile_of_a_read_only_face
    expect = [%w[a b], ["c", UNDEF]]
    assert_equal(expect, tiles(CArray.const_string(%w[a b c]).blocks(2)))
    assert_equal(expect, tiles(CA_OBJECT(%w[a b c]).categorize.blocks(2)))
    assert_equal([2, 1], CArray.const_string(%w[a b c]).blocks(2).reduce { |t| t.count_not_masked }.to_a)
  end

  def test_extreme_of_a_tile_of_a_const_string_under_min_count
    it = CArray.const_string(%w[b a c]).blocks(2)
    r = it.min(min_count: 2)
    assert_kind_of(CAConstString, r)
    assert_equal(["a", UNDEF], r.to_a.map { |v| v.nil? ? UNDEF : v })
    assert_equal(%w[a z], it.min(min_count: 2, fill_value: "z").to_a)
  end

  # ---- count(v) over a const string -------------------------------------

  def test_count_of_a_const_string_in_every_member
    c = CArray.const_string(%w[a b a c])
    codes = CA_INT32([0, 0, 1, 1]).categorize
    assert_equal([1, 1], c.blocks(2).count("a").to_a)
    assert_equal([1, 1], c.group_by_category(codes).count("a").to_a)
    assert_equal([1, 1], c.segments(offsets: CA_INT64([0, 2, 4])).count("a").to_a)
    assert_equal([1, 1, 1], c.windows(0..1, bounds: :truncate).count("a").to_a)
    assert_equal([1, 1], c.reshape(2, 2)[nil, :>].count("a").to_a)
  end

  def test_count_of_a_const_string_along_an_axis
    c = CArray.const_string(%w[a b a c]).reshape(2, 2)
    assert_equal([2, 0], c.count("a", axis: 0).to_a)
    assert_equal(2, c.count("a"))
  end

  # ---- a constant margin on a boolean -----------------------------------

  def test_extremes_over_a_boolean_with_a_constant_margin
    b = CA_BOOLEAN([true, false, true, true])
    [true, false].each { |fill|
      it = b.windows(-1..1, fill_value: fill)
      pieces = []
      it.each { |w| pieces << w.copy }
      assert_equal(pieces.map(&:min), it.min.to_a)
      assert_equal(pieces.map(&:max), it.max.to_a)
    }
  end

  # ---- running scans of tiles over a Face -------------------------------

  def test_running_scans_of_tiles_keep_the_face
    d = seconds(3, 1, 2)
    assert_kind_of(CATimedelta, d.blocks(2).cumsum)
    assert_equal(%w[3s 4s 2s], texts(d.blocks(2).cumsum))
    t = days(3, 1, 2)
    assert_kind_of(CATime, t.blocks(2).cummax)
    assert_equal(texts(t.blocks(2).cummax), texts(days(3, 3, 2)))
    f = CArray.fixlen_string(%w[s1 s2 s3], bytes: 3)
    assert_kind_of(CAFixlenString, f.blocks(2).cummax)
    assert_equal(%w[s1 s2 s3], f.blocks(2).cummax.to_a)
  end

  # ---- categorical reductions along an axis -----------------------------

  def test_stddev_and_accumulate_of_a_face_along_an_axis
    d = seconds(1, 2, 3, 5, 8, 13).reshape(3, 2)
    c = CA_INT32([0, 0, 1]).categorize
    got = d.group_by_category(c).stddev(axis: 0)
    assert_kind_of(CATimedelta, got)
    assert_equal(texts(d[0..1, nil].stddev(axis: 0)), texts(got[0, nil]))
    acc = d.group_by_category(c).accumulate(axis: 0)
    assert_kind_of(CATimedelta, acc)
    assert_equal(%w[4s 7s], texts(acc[0, nil]))
    t = days(1, 2, 3, 5).reshape(2, 2)
    assert_kind_of(CATimedelta, t.group_by_category(CA_INT32([0, 0]).categorize).stddev(axis: 0))
  end

  def test_all_and_any_along_an_axis
    b = CA_BOOLEAN([true, false, true, true, false, false]).reshape(3, 2)
    c = CA_INT32([0, 0, 1]).categorize
    it = b.group_by_category(c)
    assert_equal(b[0..1, nil].all(axis: 0).to_a, it.all(axis: 0)[0, nil].to_a)
    assert_equal(b[2..2, nil].any(axis: 0).to_a, it.any(axis: 0)[1, nil].to_a)
    assert_equal([2, 2], it.all(axis: 0).shape)
  end

  # ---- a classifier with no labels --------------------------------------

  def test_a_group_axis_without_labels_is_an_empty_axis
    c = CA_INT32([0])
    c[0] = UNDEF
    k = c.categorize
    v = CA_FLOAT64([1, 2, 3, 4]).reshape(1, 4)
    %i[sum mean min count_not_masked].each { |op|
      assert_equal([0, 4], v[k, nil].public_send(op, axis: :group).shape, op.to_s)
    }
    assert_equal([0, 2], CA_OBJECT([1, 2]).reshape(1, 2)[k, nil].sum(axis: :group).shape)
    assert_equal([1, 4], v[k, nil].cumsum(axis: :group).shape)
    assert_equal(4, v[k, nil].cumsum(axis: :group).count_masked)
  end

  # ---- the reduction keywords on a record array --------------------------

  def test_record_extremes_take_min_count_and_fill_value
    r = record(2, 1, 3)
    assert_equal(1, r.min(min_count: 3)["a"])
    assert_true(UNDEF.equal?(r.min(min_count: 4)))
    assert_equal(3, r.max(fill_value: r[0])["a"])
    e = r.copy
    e[] = UNDEF
    assert_equal(2, e.min(fill_value: r[0])["a"])
  end

  def test_record_extremes_along_an_axis
    r = record(2, 1, 3, 0).reshape(2, 2)
    r[0, 1] = UNDEF
    assert_equal(2, r.min(axis: 1).elements)
    m = r.min(axis: 1, min_count: 2)
    assert_equal(1, m.count_masked)
    assert_equal(0, r.min(axis: 1, min_count: 2, fill_value: r[1, 1]).count_masked)
  end

  def test_record_extreme_along_the_one_axis
    r = record(2, 1, 3)
    assert_equal(1, r.min(axis: 0)["a"])
    assert_equal(3, r.max(axis: 0)["a"])
    assert_equal([1], r.min(axis: 0, keep_axis: true).shape)
    assert_true(UNDEF.equal?(r.min(axis: 0, min_count: 4)))
  end

  # A block fold of string pieces holds what the block returns.
  def test_reduce_over_strings_holds_the_block_answers
    s = CArray.string(%w[s1 s2 s3])
    seg = s.segments(offsets: CA_INT64([0, 1, 3]))
    assert_equal([1, 2], seg.reduce { |x| x.elements }.to_a)
    assert_equal([1, 2], seg.reduce(0) { |acc, _| acc + 1 }.to_a)
    cat = s.group_by_category(CA_INT32([0, 1, 0]).categorize)
    assert_equal([2, 1], cat.reduce { |x| x.elements }.to_a)
  end

  # A read-only Face repeats the storage of a cell that holds the fill value.
  def test_window_fill_value_over_a_read_only_face
    c = CArray.const_string(%w[s1 s2 s3])
    assert_equal([%w[s3 s1 s2], %w[s1 s2 s3], %w[s2 s3 s3]],
                 c.windows(-1..1, fill_value: "s3").each.map(&:to_a))
    k = CArray.object(3) { %w[x y z] }.categorize
    assert_equal(%w[x x y], k.windows(-1..1, fill_value: "x").first.to_a)
    assert_raise(ArgumentError) { k.windows(-1..1, fill_value: "q").each { } }
  end

  # A Face source gives a mapped result of the same Face.
  def test_block_map_over_faces
    t = days(1, 2, 3, 4)
    r = t.blocks(2).map { |x| x.reverse }
    assert_kind_of(CATime, r)
    assert_equal(days(2, 1, 4, 3).to_a, r.to_a)
    f = CArray.fixlen_string(%w[a b c d], bytes: 3).blocks(2).map { |x| x.reverse }
    assert_kind_of(CAFixlenString, f)
    assert_equal(%w[b a d c], f.to_a)
    c = CArray.const_string(%w[a b c d]).blocks(2).map { |x| x.reverse }
    assert_equal(%w[b a d c], c.to_a)
  end
end
