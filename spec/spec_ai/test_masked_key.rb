require 'test/unit'
require 'carray'

# A masked cell used as a key, label or selector determines nothing: it
# joins no group, matches no key and selects no row; with several key
# columns one masked component is enough; two masked labels are never the
# same label.  Each entry is answered against the same question asked of
# the rows whose keys are present.
class TestMaskedKey < Test::Unit::TestCase

  KEYS = [2, 0, nil, 2, 1, 0, nil, 1, 2, 1]
  KEY2 = [0, 1, 0, nil, 1, 1, 0, 0, 0, 1]
  VALS = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

  def col (a, type = :int32)
    c = CArray.new(type, [a.size])
    a.each_with_index { |x, i| c[i] = x.nil? ? UNDEF : x }
    c
  end

  def live (*keys)
    (0...VALS.size).reject { |i| keys.any? { |k| k[i].nil? } }
  end

  def sums (rows, &key)
    rows.group_by(&key).map { |k, is| [k, is.sum { |i| VALS[i].to_f }] }.sort_by(&:first)
  end

  def frame
    CAFrame.new("k" => col(KEYS), "k2" => col(KEY2), "v" => col(VALS, :float64))
  end

  def present (f, *names)
    (0...f.nrow).map { |i| names.map { |n| x = f[n][i]; UNDEF.equal?(x) ? nil : x } }
  end

  def test_core_keys_determine_nothing
    k = col(KEYS)
    v = col(VALS, :float64)
    cat = k.categorize
    rows = live(KEYS)
    got = cat.labels.to_a.zip(v.group_by_category(cat).sum.to_a).sort_by(&:first)
    assert_equal sums(rows) { |i| KEYS[i] }, got
    by_axis = cat.labels.to_a.zip(v.reshape(10, 1)[cat, nil].sum(axis: :group).to_a.flatten)
    assert_equal sums(rows) { |i| KEYS[i] }, by_axis.sort_by(&:first)
    assert_equal [0, 1, 2].map { |x| rows.count { |i| KEYS[i] == x } }, k.bincount.to_a
    assert_equal [0, 1, 2], k.unique(sort: true).to_a
    assert_equal 3, k.nunique
    firsts = rows.select { |i| rows.find { |j| KEYS[j] == KEYS[i] } == i }
    md = k.mask_duplicates
    assert_equal firsts, (0...10).reject { |i| md.is_masked[i] }
    q = col([2, nil, 1])
    assert_equal [0, UNDEF, 4], q.locate_addr(k).to_a
    assert_equal [false, false, true], col([0, 7, 1]).is_in(q).to_a
    assert_equal [1, 2], k.intersection(q).to_a.sort
    ref = col([5, nil, 9, 7])
    assert_equal 3, ref.search(7)
    assert_equal 1, ref.count(7)
    sel = CA_BOOLEAN([true, false, true, true])
    sel[2] = UNDEF
    assert_equal [1, 4], CA_INT32([1, 2, 3, 4])[sel].to_a
  end

  def test_frame_keys_determine_nothing
    f = frame
    rows = live(KEYS)
    assert_equal sums(rows) { |i| KEYS[i] },
                 present(f.group_by("k").sum.reset_index, "k", "v").sort_by(&:first)
    both = live(KEYS, KEY2)
    s = f.group_by("k", "k2").sum
    assert_equal sums(both) { |i| [KEYS[i], KEY2[i]] }.map(&:last).sort,
                 s["v"].to_a.sort
    assert_equal [false, false, true, false],
                 CAFrame.new("k" => col([1, nil, 1, nil]), "v" => col([1, 1, 1, 1])).is_duplicate.to_a
    g = CAFrame.new("k" => col([2, nil, 1, 3]), "w" => col([200, 999, 100, 300], :float64))
    pairs = rows.flat_map { |i| [2, nil, 1, 3].each_index.select { |j| [2, nil, 1, 3][j] == KEYS[i] }.map { |j| [VALS[i].to_f, [200.0, 999.0, 100.0, 300.0][j]] } }
    assert_equal pairs.sort, present(f.join(g, on: "k", how: :inner), "v", "w").sort
    unmatched = KEYS.each_index.count { |i| KEYS[i].nil? || ![2, 1].include?(KEYS[i]) }
    assert_equal pairs.size + unmatched, f.join(g, on: "k", how: :left).nrow
    a = CAFrame.new("k" => col([0, nil, 2]), "w" => col([5.0, 6.0, 7.0], :float64))
    asof = KEYS.map { |x| x.nil? ? nil : [[0, 5.0], [2, 7.0]].select { |kk, _| kk <= x }.last&.last }
    assert_equal asof.map { |w| [w] }, present(f.join_asof(a, on: "k"), "w")
    u = CAFrame.new("k" => col([0, 1, 2, nil]), "v" => col([1.0, 2.0, 3.0, 4.0], :float64))
    assert_equal [[2, 3.0], [nil, nil], [0, 1.0]], present(u.align("k", col([2, nil, 0])), "k", "v")
    i = CAFrame.new("k" => col([5, nil, 7]), "v" => col([1.0, 2.0, 3.0], :float64)).set_index("k")
    assert_raise(ArgumentError) { i.at(UNDEF) }
    assert_equal 3.0, i.at(7)["v"]
    p = CAFrame.new("r" => col([0, 0, 1, nil, 1]), "c" => col([0, 1, nil, 0, 1]),
                    "v" => col([1.0, 2.0, 3.0, 4.0, 5.0], :float64)).pivot(index: "r", columns: "c", values: "v")
    assert_equal [[1.0, UNDEF], [2.0, 5.0]], p.column_names.map { |n| p[n].to_a }
    assert_equal K_DROPPED, present(f.filter { |x| x["k"].eq(2) }, "v").flatten
  end
  K_DROPPED = [10.0, 40.0, 90.0]

  # windows(on:, by:): a row whose by: key is masked has no window; NaN is
  # one value and -0.0 is 0.0, as a group key compares.
  def test_window_by_keys_determine_nothing
    t = CArray.int64(6).seq!
    v = CA_FLOAT64([1, 2, 3, 4, 5, 6])
    by = col([0.0, Float::NAN, nil, -0.0, Float::NAN, 0.0], :float64)
    assert_equal [1.0, 2.0, UNDEF, 5.0, 7.0, 11.0], v.windows(on: t, before: 10, by: by).sum.to_a
    b2 = col([1, 1, 1, nil, 1, 1])
    assert_equal [1.0, 2.0, UNDEF, UNDEF, 7.0, 7.0], v.windows(on: t, before: 10, by: [by, b2]).sum.to_a
  end

  # The tables above are every method that takes a key; a new one is added
  # to them, or here with the reason it is not.
  MEASURED_CARRAY = %i[categorize group_by_category bincount unique nunique mask_duplicates
                       locate_addr is_in intersection search count windows]
  NOT_MEASURED_CARRAY = {
    value_counts: "unique with counts", locate_nearest_addr: "nearest, not equality",
    difference: "the set family, through intersection", union: "the set family, through intersection",
    search_addr: "search with addresses", search_nearest: "nearest, not equality",
    search_nearest_addr: "nearest, not equality", search_ki: "the kernel search calls",
    search_addr_ki: "the kernel search_addr calls", search_nearest_ki: "the kernel search_nearest calls",
    search_nearest_addr_ki: "the kernel search_nearest_addr calls",
    count_masked: "counts masks", count_not_masked: "counts masks",
    categorize_by_breaks: "bins, not keys", group_by_run: "runs of a key, through categorize",
    bincount_nd: "the N-D form of bincount",
  }
  CARRAY_KEY_NAME = /\A(categoriz|group_by|bincount|unique|nunique|value_counts|mask_duplicates|locate|is_in\z|intersection|difference|union|search|count|windows)/

  MEASURED_FRAME = %i[group_by is_duplicate join join_asof align at pivot filter]
  NOT_MEASURED_FRAME = {
    resample: "time bins, through group_by", pivot_grid: "the cells of pivot",
    windows: "windows(on:, by:), measured on CArray",
  }
  FRAME_KEY_NAME = /\A(group_by|is_duplicate|join|align|at\z|pivot|filter|resample|windows)/

  def test_every_key_method_is_measured
    found = CArray.public_instance_methods(true).grep(CARRAY_KEY_NAME)
    assert_equal [], (found - MEASURED_CARRAY - NOT_MEASURED_CARRAY.keys).sort
    found = CAFrame.public_instance_methods(true).grep(FRAME_KEY_NAME)
    assert_equal [], (found - MEASURED_FRAME - NOT_MEASURED_FRAME.keys).sort
  end
end
