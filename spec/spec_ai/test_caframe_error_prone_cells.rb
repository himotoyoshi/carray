$:.unshift File.expand_path("../../ext", __dir__)
$:.unshift File.expand_path("../../lib", __dir__)
require "test/unit"
require "stringio"
require "zlib"
require "carray"

# The cells where a frame verb's sibling forms, its reader and writer, or a
# key's copies did not meet.
class TestCAFrameErrorProneCells < Test::Unit::TestCase

  def frame (**columns)
    CAFrame.new(columns.transform_keys(&:to_s))
  end

  def test_windows_keep_the_key_they_were_built_on
    d = frame(w: CA_INT32([0, 1, 2, 3]), x: CA_FLOAT64([1, 2, 3, 4]))
    win = d.windows(on: "w", before: 1)
    d["w"][3] = 100
    assert_equal [0, 1, 2, 3], win.last_key.to_a
    assert_equal [0, 1, 2, 3], win.bounds[1].to_a
  end

  def test_bounds_do_not_hand_out_the_key
    d = frame(a: CA_FLOAT64([1, 2]))
    d.windows(on: "a", before: 1).bounds[1][0] = 9.0
    assert_equal [1.0, 2.0], d["a"].to_a
  end

  def test_lag_refuses_a_step_that_is_no_integer
    d = frame(x: CA_FLOAT64([1, 2, 3]))
    assert_raise(TypeError) { d.lag(n: 1.5) }
    assert_raise(TypeError) { d.lag("x", n: "a") }
  end

  def test_nd_window_reductions_keep_the_face
    t = CArray.time(Array.new(6) { |i| "2024-01-0#{i + 1}" }).reshape(3, 2)
    d = frame(k: CA_INT32([0, 1, 2]), t: t)
    out = d.windows(on: "k", before: 1).min("t")
    assert_kind_of CATime, out
    assert_equal t[0, 0].to_s, out[0, 0].to_s
    s = CArray.string(%w[a b c d e f]).reshape(3, 2)
    assert_kind_of CAString, frame(k: CA_INT32([0, 1, 2]), s: s).windows(on: "k", before: 1).min("s")
  end

  def test_window_fill_value_by_column
    d = frame(k: CA_INT32([0, 1]), x: CArray.float64(2) { |i| i == 0 ? UNDEF : 1.0 })
    w = d.windows(on: "k", before: 0, exclude: nil)
    assert_equal [9.0, 1.0], w.mean("x", fill_value: { "x" => 9.0 }).to_a
    assert_raise(ArgumentError) { w.mean("x", fill_value: { "y" => 9.0 }) }
  end

  def test_group_quantile_of_an_nd_column
    d = frame(g: CA_INT32([0, 1, 0]), n: CArray.float64(3, 2).seq)
    q = d.group_by("g").quantile("n")
    p50 = d.group_by("g").percentile(50, "n")
    assert_equal p50["n"].to_a, q["n_p50"].to_a
  end

  def test_group_cumcount_of_no_rows_and_of_fixed_bytes
    empty = frame(g: CA_INT32([]), s: CArray.string([]))
    assert_equal :int64, empty.group_by("g").cumcount("s").data_type.then { CArray.data_type_name(_1).to_sym }
    fix = frame(g: CA_INT32([0, 1, 0]), f: CArray.fixlen(3, bytes: 1) { "a" })
    assert_equal [1, 1, 2], fix.group_by("g").cumcount("f").to_a
  end

  def test_tolerance_does_not_wrap
    assert_equal [UNDEF], CA_UINT8([200]).locate_nearest_addr(CA_UINT8([0]), tolerance: 100).to_a
    assert_equal [0], CA_UINT8([200]).locate_nearest_addr(CA_UINT8([0]), tolerance: 200).to_a
    assert_equal [UNDEF], CA_INT8([127]).locate_nearest_addr(CA_INT8([-128]), tolerance: 1).to_a
    big = 2**63 - 1
    assert_equal [UNDEF], CA_INT64([big]).locate_nearest_addr(CA_INT64([-big]), tolerance: 1).to_a
    assert_equal [UNDEF], CA_INT32([16777217]).locate_nearest_addr(CA_FLOAT32([16777216.0]), tolerance: 0).to_a
  end

  def test_a_nan_in_an_object_key_matches_nothing
    assert_equal [UNDEF],
                 CA_OBJECT([Float::NAN]).locate_nearest_addr(CA_FLOAT64([1, 5]), tolerance: 0).to_a
    assert_equal [0],
                 CA_OBJECT([1.0]).locate_nearest_addr(CA_OBJECT([1.0, Float::NAN]), tolerance: 0).to_a
  end

  def test_asof_across_calendar_and_fixed_units
    l = frame(k: CArray.time(["2024-02-01"], unit: :M))
    r = frame(k: CArray.time(["2024-01-15"], unit: :D), v: CA_INT32([1]))
    assert_equal [1], l.join_asof(r, on: "k")["v"].to_a
  end

  def test_an_object_column_cast_to_string_is_a_new_column
    d = frame(o: CA_OBJECT(["a", UNDEF]))
    r = d.cast("o" => :string)
    r.fill("o", "Z")
    assert_equal ["a", UNDEF], d["o"].to_a
  end

  def test_timedelta_text_that_does_not_read_follows_on_error
    %w[99999999999999999999s].push("3 @ 0 m").each do |text|
      d = frame(a: CA_OBJECT([text]))
      assert_equal [UNDEF], d.cast({ "a" => :timedelta }, on_error: :mask)["a"].to_a
      assert_raise(CAFrame::UnreadableColumn) { d.cast({ "a" => :timedelta }, on_error: :raise) }
    end
  end

  def test_an_array_key_of_types_holds_for_a_blank_cell
    d = CAFrame.from_csv("a,b\n\"\",1\n2.5,3\n", types: { ["a", "b"] => :float64 })
    assert_equal [UNDEF, 2.5], d["a"].to_a
  end

  def test_a_named_infer_in_types
    assert_equal :int64, CAFrame.from_csv("a,b\n1,x\n", types: { "a" => :infer })["a"].data_type.then { CArray.data_type_name(_1).to_sym }
  end

  def test_columns_refuses_a_range_with_no_column
    [0..-1, 1..0, 0...0].each do |r|
      assert_raise(ArgumentError, r.inspect) { CAFrame.from_csv("a,b,c\n1,x,2.5\n", columns: [r]) }
    end
  end

  def test_a_gzip_reader_reads_as_text
    io = StringIO.new
    z = Zlib::GzipWriter.new(io)
    z.write("a\n1\n")
    z.close
    assert_equal ["1"], CAFrame.read_csv(Zlib::GzipReader.new(StringIO.new(io.string)), types: :string)["a"].to_a
  end

  def test_to_csv_checks_what_the_reader_checks
    d = frame(a: CA_INT32([1]))
    assert_raise(ArgumentError) { d.to_csv(quote: "") }
    assert_raise(ArgumentError) { d.to_csv(sep: "") }
    assert_raise(ArgumentError) { d.to_csv(sep: "\n") }
  end

  def test_a_backslash_quote_round_trips
    text = frame(a: CA_OBJECT(['a\\b'])).to_csv(quote: "\\")
    assert_equal ['a\\b'], CAFrame.from_csv(text, quote: "\\")["a"].to_a
  end

  def test_stack_columns_and_melt_refuse_in_their_own_words
    d = frame(a: CArray.time(["2024-01-01"], unit: :D), b: CArray.time(["2024-01-01"], unit: :h))
    err = assert_raise(ArgumentError) { d.stack_columns(%w[a b], into: "c") }
    assert_match(/\Astack_columns: /, err.message)
    assert_no_match(/promote_list/, err.message)
    f = frame(a: CArray.fixlen(1, bytes: 1) { "a" }, b: CArray.fixlen(1, bytes: 3) { "abc" })
    err = assert_raise(ArgumentError) { f.melt(value_columns: %w[a b]) }
    assert_match(/\Amelt: /, err.message)
  end

  def test_a_verb_over_every_column_leaves_out_an_object_column_that_does_not_answer
    assert_equal ["x"], frame(h: CA_OBJECT([{ a: 1 }, { b: 2 }]), x: CA_FLOAT64([1, 2])).min.column_names
    [[1, "a", 2], ["a", 1, 2]].each do |cells|
      assert_equal ["x"], frame(o: CA_OBJECT(cells), x: CA_INT32([1, 2, 3])).sum.column_names
    end
    assert_raise(TypeError) { frame(o: CA_OBJECT([1, "a", 2])).sum("o") }
  end

  def test_an_integer_past_2_53_beside_a_float_stays_exact
    col = CAFrame.from_records([{ "a" => 2**53 + 1 }, { "a" => 0.5 }])["a"]
    assert_equal :object, CArray.data_type_name(col.data_type).to_sym
    assert_equal 2**53 + 1, col[0]
  end

  def test_a_result_has_its_own_index
    d = CAFrame.new({ "g" => CA_INT32([0, 1]), "x" => CA_INT32([1, 2]) }, index: CA_INT32([5, 6]))
    d.windows(on: "x", before: 1).mean.index[0] = -1
    assert_equal [5, 6], d.index.to_a
  end

  def test_promote_leaves_a_column_of_the_type_as_it_is
    d = frame(a: CA_FLOAT64([1]), b: CA_INT32([1]))
    assert_same d["a"], d.promote(:float64)["a"]
  end

  def test_at_finds_a_complex_nan
    d = CAFrame.new({ "v" => CA_INT32([1]) }, index: CArray.cmplx128(1) { Complex(Float::NAN, 0) })
    assert_equal 1, d.at(Complex(Float::NAN, 0))["v"]
  end

  def test_meld_holds_the_index_to_the_rule_of_the_columns
    a = CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_INT64([1]))
    b = CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_FLOAT64([2]))
    err = assert_raise(ArgumentError) { CAFrame.meld(a, b) }
    assert_match(/\Ameld: /, err.message)
  end

  def test_a_year_past_four_digits_reads_back
    d = frame(t: CA_INT64([50, 9000]).time(unit: :Y))
    back = CAFrame.from_csv(d.to_csv, types: { "t" => :time })["t"]
    assert_equal d["t"].to_a.map(&:to_s), back.to_a.map(&:to_s)
  end

  def test_a_key_past_what_the_common_float_holds_is_refused
    big = frame(k: CA_INT64([2**53 + 1]), x: CA_INT32([1]))
    f = frame(k: CA_FLOAT64([2.0**53]), y: CA_INT32([2]))
    [-> { big.join(f, on: "k") }, -> { f.join(big, on: "k", how: :outer) },
     -> { big.join_asof(f, on: "k") }, -> { big.join(f, on: "k", how: :semi) },
     -> { big.align("k", CA_FLOAT64([2.0**53])) }].each do |call|
      err = assert_raise(ArgumentError) { call.call }
      assert_match(/9007199254740993, past 2\*\*53, beyond which float64 does not hold every integer/, err.message)
    end
    err = assert_raise(ArgumentError) { CAFrame.concatenate(big.select("k"), f.select("k")) }
    assert_match(/\Aconcatenate: column "k" holds/, err.message)
  end

  def test_keys_a_float_holds_still_meet
    i = frame(k: CA_INT64([2**53, -2**53, 3]), x: CA_INT32([1, 2, 3]))
    f = frame(k: CA_FLOAT64([3.0]), y: CA_INT32([2]))
    assert_equal 1, i.join(f, on: "k", how: :inner).nrow
    assert_equal 4, CAFrame.concatenate(i.select("k"), f.select("k")).nrow
  end

  def test_a_masked_cell_is_no_key_past_the_float
    i = frame(k: CArray.int64(2) { |n| n == 0 ? UNDEF : 3 })
    i["k"][0] = 2**53 + 1
    i["k"][0] = UNDEF
    assert_equal 1, i.join(frame(k: CA_FLOAT64([3.0])), on: "k", how: :inner).nrow
  end

  def test_a_wrong_keyword_is_not_taken_for_a_column_that_does_not_answer
    d = frame(g: CA_INT32([0, 1]), o: CA_OBJECT([1, 2]))
    assert_raise(ArgumentError) { d.sum(min_count: -1) }
    assert_raise(ArgumentError) { d.group_by("g").sum(min_count: -1) }
    assert_raise(ArgumentError) { d.windows(on: "g", before: 1).sum(min_count: -1) }
  end

  def test_a_complex_cell_leaves_out_of_a_float_only_reduction
    d = frame(o: CA_OBJECT([1, Complex(0, 1), 2]), x: CA_FLOAT64([1, 2, 3]))
    assert_equal ["x"], d.stddev.column_names
  end

  def test_a_fill_writes_only_the_cells_it_filled
    make = -> { a = CArray.float64(2) { |i| i == 0 ? UNDEF : 200.0 }; [a, a[CA_INT64([0, 1, 0])]] }
    [->(d) { d.fill("v" => :bfill) }, ->(d) { d.fill(:bfill) }, ->(d) { d.fill(["v"], :bfill) }].each do |call|
      a, v = make.call
      call.call(frame(v: v))
      assert_equal [200.0, 200.0], a.to_a
    end
    a, v = make.call
    frame(g: CA_INT32([0, 0, 0]), v: v).group_by("g").fill("v", :bfill)
    assert_equal [200.0, 200.0], a.to_a
    a = CArray.float64(3) { |i| [UNDEF, 1.0, 3.0][i] }
    CAFrame.new({ "v" => a[CA_INT64([1, 0, 2, 0])] }, index: CA_FLOAT64([1, 2, 3, 4])).fill("v", :linear)
    assert_equal 2.0, a[0]
  end

  def test_asof_by_measures_and_leaves_out_as_without_by
    l = frame(b: CA_INT32([0]), k: CA_INT8([-128]))
    r = frame(b: CA_INT32([0]), k: CA_INT8([126]), y: CA_INT32([9]))
    assert_equal [UNDEF], l.join_asof(r, on: "k", by: "b", direction: :ceil, tolerance: 5)["y"].to_a
    l = frame(b: CA_INT32([0]), k: CA_OBJECT([Float::NAN]))
    r = frame(b: CA_INT32([0]), k: CA_FLOAT64([1]), y: CA_INT32([9]))
    assert_equal [UNDEF], l.join_asof(r, on: "k", by: "b")["y"].to_a
  end

  def test_stack_verbs_refuse_a_rounded_integer_too
    i = frame(k: CA_INT64([2**53 + 1]))
    f = frame(k: CA_FLOAT64([1.0]))
    assert_raise(ArgumentError) { CAFrame.stack(i, f) }
    assert_raise(ArgumentError) { frame(a: i["k"], b: f["k"]).stack_columns(%w[a b], into: "c") }
  end

  def test_at_does_not_round_a_label
    assert_raise(KeyError) { CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_INT64([2**53 + 1])).at(2.0**53) }
    assert_raise(KeyError) { CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_FLOAT64([2.0**53])).at(2**53 + 1) }
    assert_equal 1, CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_INT64([3])).at(3.0)["v"]
  end

  def test_timedelta_count_that_does_not_fit_follows_on_error
    assert_equal [UNDEF], frame(a: CA_OBJECT(["1 @ 99999999999999999999 s"])).cast({ "a" => :timedelta }, on_error: :mask)["a"].to_a
  end

  def test_concatenate_says_its_refusal_with_the_column
    a = frame(a: CArray.fixlen(1, bytes: 1) { "a" })
    err = assert_raise(CArray::DataTypeError) { CAFrame.concatenate(a, frame(a: CA_INT32([1]))) }
    assert_match(/\Aconcatenate: column "a": /, err.message)
  end

  def test_cast_of_one_name_takes_infer
    assert_equal :int64, CArray.data_type_name(frame(a: CA_OBJECT(%w[1 2])).cast("a", :infer)["a"].data_type).to_sym
  end

  def test_resample_fill_on_a_year_with_an_origin
    d = frame(t: CArray.time(%w[2024-03-10 2024-06-10 2025-03-10], unit: :D), v: CA_INT32([1, 2, 4]))
    plain = d.resample("t", "1 year", origin: "2024-02-01").sum("v")
    filled = d.resample("t", "1 year", origin: "2024-02-01", fill: true).sum("v")
    assert_equal plain["v"].to_a, filled["v"].to_a
    assert_equal plain.index.to_a.map(&:to_s), filled.index.to_a.map(&:to_s)
  end

  def test_resample_fill_on_a_key_coarser_than_the_unit
    d = frame(t: CArray.time(%w[2024 2025], unit: :Y), v: CA_INT32([1, 2]))
    assert_equal [1.0, 2.0], d.resample("t", "6 months", fill: true).sum("v")["v"].to_a
  end

  def test_group_verbs_ask_for_their_block
    g = frame(g: CA_INT32([0, 1])).group_by("g")
    assert_raise(ArgumentError) { g.filter }
    assert_raise(ArgumentError) { g.table }
  end

  def test_a_frame_with_no_witness_checks_a_selector
    assert_raise(IndexError) { CAFrame.new[CA_INT64([0, 1])] }
    assert_raise(IndexError, ArgumentError) { CAFrame.new[CArray.boolean(3) { true }] }
  end

  def test_fill_refuses_an_unknown_method_with_nothing_to_fill
    assert_raise(ArgumentError) { CAFrame.new.fill(:bogus) }
    assert_raise(ArgumentError) { frame(a: CA_INT32([1])).fill(:bogus) }
  end

  def test_a_window_at_points_refuses_its_key_in_its_own_words
    d = frame(f: CA_FLOAT64([1, 2]))
    err = assert_raise(ArgumentError) { d.windows(on: "f", before: 1, at: CA_FLOAT64([1])).sum("f") }
    assert_match(/\Asum: "f" is the key/, err.message)
  end

  def test_at_finds_a_nan_label_of_a_categorical
    d = CAFrame.new({ "v" => CA_INT32([1]) }, index: CA_FLOAT64([Float::NAN]).categorize)
    assert_equal 1, d.at(Float::NAN)["v"]
  end

  def test_to_csv_finds_the_missing_token_in_another_encoding
    d = frame(a: CA_OBJECT(["\u6B20".encode("CP932"), "x"]))
    assert_raise(ArgumentError) { d.to_csv(missing: "\u6B20") }
  end

  def test_inference_keeps_an_integer_a_float_would_round_as_text
    assert_kind_of CAString, CAFrame.from_csv("a\n9007199254740993\n0.5\n")["a"]
    assert_equal :float64, CArray.data_type_name(CAFrame.from_csv("a\n9007199254740992\n0.5\n")["a"].data_type).to_sym
    assert_equal({}, frame(a: CA_OBJECT(%w[9007199254740993 0.5])).infer_types)
  end

  def test_refusals_name_the_column
    err = assert_raise(ArgumentError) { frame(a: CA_OBJECT([1, "a-b"])).split_column("a", "-", into: %w[x y]) }
    assert_match(/\Asplit_column: row 0 of "a"/, err.message)
    c = frame(c: CA_OBJECT(["a", UNDEF]).categorize)
    err = assert_raise(RuntimeError) { c.fill("c", "z") }
    assert_match(/\Afill: column "c"/, err.message)
  end

  def test_select_string_reads_nil_as_missing
    d = frame(s: CA_OBJECT(["a", nil]), n: CA_INT32([1, 2]))
    assert_equal ["s"], d.select(:string).column_names
  end

  def test_lag_refuses_a_complex_key
    d = frame(k: CArray.cmplx128(2) { |i| Complex(i, 0) }, x: CA_FLOAT64([1, 2]))
    assert_raise(ArgumentError) { d.lag("x", before: 1, on: "k") }
  end

  def test_a_row_verb_with_no_column_to_compute_is_refused
    d = frame(a: CA_INT32([1, 2]))
    assert_raise(ArgumentError) { d.group_by("a").cumcount }
    assert_raise(ArgumentError) { frame(o: CA_OBJECT([nil, nil])).cumsum }
  end

  def test_group_and_window_first_keep_a_read_only_face
    c = CA_OBJECT(["a", UNDEF, "b", "c"]).categorize
    d = frame(g: CA_INT32([0, 0, 1, 1]), k: CA_INT32([1, 2, 3, 4]), c: c)
    f = d.group_by("g").first("c")["c"]
    assert_kind_of CACategorical, f
    assert_equal ["a", "b"], f.to_a
    assert_equal ["a", "c"], d.group_by("g").last("c")["c"].to_a
    w = d.windows(on: "k", before: 1).first("c")
    assert_kind_of CACategorical, w
    plain = frame(k: d["k"], c: CA_OBJECT(["a", UNDEF, "b", "c"])).windows(on: "k", before: 1).first("c")
    assert_equal plain.to_a, w.to_a
  end

  def test_concatenate_brings_a_face_to_one_state
    a = frame(t: CArray.time(["2024-01-01"], unit: :D))
    b = frame(t: CArray.time(["2024-01-01T06:00:00"], unit: :h))
    t = CAFrame.concatenate(a, b)["t"]
    assert_equal CATime::Resolution.parse(:h), t.unit
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z"], t.to_a.map(&:to_s)
    x = frame(c: CA_OBJECT(%w[a b]).categorize)
    y = frame(c: CA_OBJECT(%w[c a]).categorize)
    c = CAFrame.concatenate(x, y)["c"]
    assert_kind_of CACategorical, c
    assert_equal %w[a b c a], c.to_a
    assert_equal %w[a b c], c.labels
  end

  def test_splice_into_an_indexed_frame_needs_an_index_even_with_no_rows
    with = CAFrame.new({ "v" => CA_INT32([1, 2]) }, index: CA_INT32([5, 6]))
    without = frame(v: CA_INT32([9]))
    assert_raise(ArgumentError) { with.copy[0..0] = without }
    assert_raise(ArgumentError) { with.copy[0..0] = without[CA_INT64([])] }
  end

  def test_precision_rounds_a_complex_with_an_integer_part
    assert_equal "a\n1+2.3i\n", frame(a: CA_OBJECT([Complex(1, 2.345)])).to_csv(precision: 1)
  end

  def test_to_a_keeps_the_rows_of_a_column_with_no_cells
    df = frame(a: CArray.int32(3, 0), b: CA_INT32([1, 2, 3]))
    assert_equal [[[], 1], [[], 2], [[], 3]], df.to_a
    assert_equal [[], [], []], CArray.int32(3, 0).to_a
    assert_equal [[], []], CArray.int32(2, 0, 4).to_a
    assert_equal [], CArray.int32(0, 4).to_a
  end

  def test_an_all_masked_text_column_stays_out_of_a_sum_over_every_column
    s = CArray.string(%w[a b c])
    s[] = UNDEF
    df = frame(t: CA_INT32([1, 2, 3]), s: s, x: CA_INT32([1, 2, 3]))
    assert_equal %w[t x], df.sum.column_names
    assert_equal %w[x], df.group_by("t").sum.column_names
    assert_equal %w[x], df.windows(on: "t", before: 1).sum.column_names
  end

  def test_a_text_key_has_no_distance_for_round_or_tolerance
    l = frame(k: CA_OBJECT(%w[x y z]), g: CA_INT32([1, 1, 1]), v: CA_INT32([1, 2, 3]))
    r = frame(k: CA_OBJECT(%w[y]), g: CA_INT32([1]), w: CA_INT32([9]))
    assert_equal [UNDEF, 9, 9], l.join_asof(r, on: "k")["w"].to_a
    e = assert_raise(ArgumentError) { l.join_asof(r, on: "k", tolerance: 1) }
    assert_match(/join_asof: tolerance: .*String has no -/, e.message)
    assert_raise(ArgumentError) { l.join_asof(r, on: "k", by: "g", direction: :round) }
    assert_raise(ArgumentError) { CA_OBJECT(%w[x y]).locate_nearest_addr(CA_OBJECT(%w[y])) }
  end

  def test_a_tolerance_measures_time_keys_farther_apart_than_int64_nanoseconds
    days = %w[1700-01-01 2024-01-03 2200-01-03]
    l = frame(t: CArray.time(days, unit: :ns), g: CA_INT32([1, 1, 1]), v: CA_INT32([1, 2, 3]))
    r = frame(t: CArray.time(%w[2024-01-02], unit: :ns), g: CA_INT32([1]), w: CA_INT32([3]))
    assert_equal [UNDEF, 3, UNDEF], l.join_asof(r, on: "t", tolerance: "1 day", direction: :round)["w"].to_a
    assert_equal [UNDEF, 3, UNDEF], l.join_asof(r, on: "t", by: "g", tolerance: "1 day", direction: :round)["w"].to_a
    assert_equal [UNDEF, 3, 3], l.join_asof(r, on: "t", tolerance: "100000 days", direction: :round)["w"].to_a
  end

  def test_a_reduction_names_itself_for_a_name_that_is_no_column
    df = frame(k: CA_INT32([1, 1, 2]), v: CA_FLOAT64([1, 2, 3]))
    { "sum" => -> { df.sum("nope") },
      "cumsum" => -> { df.group_by("k").cumsum("nope") },
      "first" => -> { df.windows(on: "v", before: 1).first("nope") },
      "aggregate" => -> { df.group_by("k").aggregate("x" => ["nope", ->(c) { c.sum }]) } }.each do |verb, call|
      e = assert_raise(KeyError) { call.call }
      assert_equal "#{verb}: no column \"nope\"", e.message
    end
  end


  def test_at_on_a_float32_index_does_not_round_a_label
    f = CAFrame.new("i" => CA_FLOAT32([16777216.0, 1.0]), "v" => CA_INT32([1, 2])).set_index("i")
    assert_equal 1, f.at(16777216)["v"]
    assert_raise(KeyError) { f.at(16777217) }
    g = CAFrame.new("i" => CA_FLOAT64([1.0, 2.0]), "v" => CA_INT32([1, 2])).set_index("i")
    assert_raise(KeyError) { g.at(2**1100) }
  end

  def test_infer_types_keeps_an_object_column_of_integers_past_a_float
    assert_equal({}, CAFrame.new("a" => CA_OBJECT([2**53 + 1, 1.5])).infer_types)
    assert_equal({ "a" => :float64 }, CAFrame.new("a" => CA_OBJECT([2**53, 1.5])).infer_types)
  end

  def test_concatenate_keeps_the_shape_of_categorical_pieces_relabelled
    a = CA_OBJECT(%w[x y x y]).reshape(2, 2)
    a[1, 1] = UNDEF
    p1 = CAFrame.new("c" => a.categorize, "n" => CA_INT32([1, 2]))
    p2 = CAFrame.new("c" => CA_OBJECT(%w[z x z x]).reshape(2, 2).categorize, "n" => CA_INT32([3, 4]))
    r = CAFrame.concatenate(p1, p2)
    assert_equal [4, 2], r["c"].shape
    assert_equal [["x", "y"], ["x", UNDEF], ["z", "x"], ["z", "x"]], r["c"].to_a
    assert_equal %w[x y z], r["c"].labels
  end

  def test_verify_gives_its_result_an_index_of_its_own
    f = CAFrame.new("a" => CA_FLOAT64([1, 2, 3]), "i" => CA_INT32([10, 20, 30])).set_index("i")
    r = f.verify("a" => ->(df) { df["a"] > 1 })
    r.index[0] = 99
    assert_equal [10, 20, 30], f.index.to_a
  end
end
