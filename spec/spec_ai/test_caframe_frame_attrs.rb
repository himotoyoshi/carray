require "test/unit"
require "carray"

# The attributes of a frame as a whole (CAFrame#attr / #set_attr ...): the
# key and value rules, and which frames made from a frame take them.
#
# A frame that holds the same table -- a selection of rows, a change of
# columns, a copy -- takes them; a frame computed from it does not.  Every
# public method of CAFrame is listed below in one of the groups, so a method
# added without being classified fails test_every_method_is_classified.

class TestCAFrameFrameAttrs < Test::Unit::TestCase
  ATTRS = { "title" => "hourly observations", "source" => "station network" }.freeze

  def frame
    CAFrame.new({ "k" => CA_INT64([1, 2, 3, 2]),
                  "g" => CA_OBJECT(%w[a b a b]),
                  "v" => CA_FLOAT64([1.5, 2.5, 3.5, 4.5]),
                  "s" => CA_OBJECT(%w[x-1 y-2 z-3 w-4]),
                  "t" => CA_OBJECT(%w[2024-01-01 2024-01-02 2024-01-03 2024-01-04]),
                  "w" => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8]]) },
                attrs: ATTRS)
  end

  def other
    CAFrame.new("k" => CA_INT64([1, 2]), "z" => CA_INT32([10, 20]))
  end

  # Frames holding the same table: they take the attributes.
  CARRIES = {
    :[]               => ->(df, _) { df[0..1] },
    :filter           => ->(df, _) { df.filter { |f| f["v"] > 2 } },
    :drop_masked      => ->(df, _) { df.drop_masked },
    :strip_mask       => ->(df, _) { df.strip_mask(0.0) },
    :head             => ->(df, _) { df.head(2) },
    :tail             => ->(df, _) { df.tail(2) },
    :sort_by          => ->(df, _) { df.sort_by { |f| f["v"] } },
    :sort_by_key      => ->(df, _) { df.sort_by_key("k") },
    :nlargest         => ->(df, _) { df.nlargest(2, "k") },
    :nsmallest        => ->(df, _) { df.nsmallest(2, "k") },
    :select           => ->(df, _) { df.select("k", "v") },
    :append           => ->(df, _) { df.append("x", CA_INT32([1, 2, 3, 4])) },
    :drop             => ->(df, _) { df.drop("v") },
    :rename           => ->(df, _) { df.rename("v" => "value") },
    :contrast_columns => ->(df, _) { df.cast("g" => :categorical).contrast_columns("g") },
    :split_column     => ->(df, _) { df.split_column("s", "-", into: ["a", "b"]) },
    :stack_columns    => ->(df, _) { df.stack_columns(["k", "v"], into: "kv") },
    :unstack_column   => ->(df, _) { df.unstack_column("w") },
    :copy             => ->(df, _) { df.copy },
    :transform        => ->(df, _) { df.transform("v") { |c| c * 2 } },
    :cast             => ->(df, _) { df.cast("k" => :float64) },
    :promote          => ->(df, _) { df.promote(:object) },
    :set_index        => ->(df, _) { df.set_index("k") },
    :reset_index      => ->(df, _) { df.set_index("k").reset_index },
    :parse_to_time    => ->(df, _) { df.parse_to_time("t") },
    :to_time          => ->(df, _) { df.cast("k" => :int64).to_time("k") },
  }.freeze

  # Verbs that change the frame itself and return it.
  RETURNS_SELF = {
    :mask_eq       => ->(df) { df.mask_eq("k", 2) },
    :fill          => ->(df) { df.fill("v", 0.0) },
    :protect       => ->(df) { df.protect },
    :set_column_attrs => ->(df) { df.set_column_attrs(df.attrs) },
  }.freeze

  # Frames computed from this one: they do not take the attributes.
  DROPS = {
    :join          => ->(df, o) { df.join(o, on: "k") },
    :join_asof     => ->(df, o) { df.join_asof(o, on: "k") },
    :paste         => ->(df, _) { df.paste(CAFrame.new("q" => CA_INT32([1, 2, 3, 4]))) },
    :align         => ->(df, _) { df.align("k", CA_INT64([1, 2])) },
    :describe      => ->(df, _) { df.describe },
    :value_counts  => ->(df, _) { df.value_counts("g") },
    :verify        => ->(df, _) { df.verify("positive" => ->(f) { f["v"] > 0 }) },
    :group_by      => ->(df, _) { df.group_by("g").aggregate("n" => ["v", :count]) },
    :melt          => ->(df, _) { df.select("k", "v").melt(id: ["k"]) },
    :pivot         => ->(df, _) { df.pivot(index: "g", columns: "k", values: "v", aggregate: :mean) },
    :stack_rows    => ->(df, _) { df.select("g", "v").stack_rows(by: "g") },
    :unstack_rows  => ->(df, _) { df.select("k", "w").unstack_rows },
    :unstack       => ->(df, _) { df.select("w").unstack(axis: 1).first },
    :resample      => ->(df, _) { df.parse_to_time("t").resample("t", "2 days").mean },
    :windows       => ->(df, _) { df.windows(on: "k", before: 1).mean },
    :lag           => ->(df, _) { df.lag(n: 1) },
    :order         => ->(df, _) { df.order },
    :cumsum        => ->(df, _) { df.cumsum },
    :cumprod       => ->(df, _) { df.cumprod },
    :cummax        => ->(df, _) { df.cummax },
    :cummin        => ->(df, _) { df.cummin },
    :cumcount      => ->(df, _) { df.cumcount },
    :sum           => ->(df, _) { df.sum },
    :mean          => ->(df, _) { df.mean },
    :min           => ->(df, _) { df.min },
    :max           => ->(df, _) { df.max },
    :prod          => ->(df, _) { df.prod },
    :accumulate    => ->(df, _) { df.accumulate },
    :median        => ->(df, _) { df.median },
    :percentile    => ->(df, _) { df.percentile(50) },
    :quantile      => ->(df, _) { df.quantile },
    :variance      => ->(df, _) { df.variance },
    :stddev        => ->(df, _) { df.stddev },
    :variancep     => ->(df, _) { df.variancep },
    :stddevp       => ->(df, _) { df.stddevp },
    :first         => ->(df, _) { df.first },
    :last          => ->(df, _) { df.last },
    :nunique       => ->(df, _) { df.nunique },
    :count         => ->(df, _) { df.count },
    :all           => ->(df, _) { df.all },
    :any           => ->(df, _) { df.any },
  }.freeze

  # Public methods that return no frame made from this one.
  NOT_A_FRAME = %i[
    == []= at axis_name column_names columns data_types each_row index
    infer_time_format infer_types inspect is_duplicate ncol nrow shape empty? pivot_grid protected?
    to_a to_ca to_csv to_records to_s to_table write_csv
    attr set_attr set_attrs delete_attr attrs attrs_symkey has_attr?
  ].freeze

  CLASS_DROPS = {
    :meld        => ->(df) { CAFrame.meld(df, df) },
    :concatenate => ->(df) { CAFrame.concatenate(df, df) },
    :paste       => ->(df) { CAFrame.paste(df, CAFrame.new("q" => CA_INT32([1, 2, 3, 4]))) },
    :stack       => ->(df) { CAFrame.stack(df.select("v"), df.select("v")) },
  }.freeze

  CLASS_NOT_A_FRAME = %i[read_csv from_csv from_records].freeze

  def test_every_method_is_classified
    listed = CARRIES.keys + RETURNS_SELF.keys + DROPS.keys + NOT_A_FRAME
    assert_equal [], (CAFrame.public_instance_methods(false) - listed).sort
    assert_equal [], (CAFrame.singleton_methods(false) - CLASS_DROPS.keys - CLASS_NOT_A_FRAME).sort
  end

  def test_frames_of_the_same_table_take_the_attributes
    CARRIES.each do |name, make|
      assert_equal ATTRS, make.call(frame, other).attrs, "#{name} should carry the attributes"
    end
  end

  def test_verbs_returning_self_keep_them
    RETURNS_SELF.each do |name, make|
      df = frame
      assert_same df, make.call(df), "#{name} should return self"
      assert_equal ATTRS, df.attrs, "#{name} should keep the attributes"
    end
  end

  def test_computed_frames_do_not_take_them
    DROPS.each do |name, make|
      out = make.call(frame, other)
      assert_kind_of CAFrame, out, name.to_s
      assert_equal({}, out.attrs, "#{name} should not carry the attributes")
    end
    CLASS_DROPS.each do |name, make|
      assert_equal({}, make.call(frame).attrs, "CAFrame.#{name} should not carry the attributes")
    end
  end

  def test_join_semi_and_anti_carry
    assert_equal ATTRS, frame.join(other, on: "k", how: :semi).attrs
    assert_equal ATTRS, frame.join(other, on: "k", how: :anti).attrs
  end

  def test_grouped_frame_filter_and_parts_carry
    grp = frame.group_by("g")
    assert_equal ATTRS, grp.filter { CA_BOOLEAN([true, false]) }.attrs
  end

  def test_each_frame_has_its_own_hash
    df = frame
    sub = df.head(2)
    sub.set_attr(:title, "changed")
    dup = df.dup
    dup.set_attr(:extra, 1)
    assert_equal ATTRS, df.attrs
    assert_equal "changed", sub.attr(:title)
  end

  def test_key_and_value_rules
    df = CAFrame.new("a" => CA_INT32([1]))
    df.set_attr(:unit, [:m, { k: :s }])
    assert_equal({ "unit" => ["m", { "k" => "s" }] }, df.attrs)
    assert df.attr("unit").frozen?
    assert df.attrs.frozen?
    assert df.has_attr?
    assert df.has_attr?(:unit)
    assert_raise(TypeError) { df.set_attr(:x, Object.new) }
    assert_raise(TypeError) { df.set_attr(1, "x") }
    assert_raise(TypeError) { df.set_attrs([1]) }
    e = assert_raise(TypeError) { CAFrame.new({ "a" => CA_INT32([1]) }, attrs: [1]) }
    assert_match(/CAFrame\.new: attrs: takes a Hash/, e.message)
    assert_equal ["m", { "k" => "s" }], df.delete_attr(:unit)
    assert_nil df.delete_attr(:unit)
    assert !df.has_attr?
  end

  def test_attrs_symkey
    h = frame.attrs_symkey
    assert_equal({ title: "hourly observations", source: "station network" }, h)
    assert h.frozen?
    assert_equal({}, other.attrs_symkey)
    df = other
    df.set_attr(:info, { "k" => [{ "x" => 1 }] })
    assert_equal({ info: { k: [{ x: 1 }] } }, df.attrs_symkey)
  end

  def test_rejected_value_leaves_the_frame_unchanged
    df = frame
    assert_raise(TypeError) { df.set_attrs(a: 1, b: Object.new) }
    assert_equal ATTRS, df.attrs
  end

  def test_protected_frame_refuses_writes
    df = frame.protect
    err = assert_raise(FrozenError) { df.set_attr(:a, 1) }
    assert_match(/\Acan't modify frozen CAFrame \(\d+ rows?, \d+ columns?\)\z/, err.message)
    assert_raise(FrozenError) { df.delete_attr(:title) }
    assert_equal ATTRS, df.attrs
  end

  # set_column_attrs with no attributes: each column takes its own name as
  # "name"; the frame's own attributes are not touched.
  def test_set_column_attrs_names
    df = frame
    df["v"].set_attr(:units, "m")
    assert_same df, df.set_column_attrs
    df.column_names.each { |name| assert_equal name, df[name].attr("name") }
    assert_equal({ "units" => "m", "name" => "v" }, df["v"].attrs)
    assert_equal ATTRS, df.attrs
    # a column taken out of a selection of rows still shows it
    assert_equal "v", df[0..1]["v"].attr("name")
  end

  # With attributes, they are set and "name" is not.
  def test_set_column_attrs_on_every_column
    df = frame
    df.set_column_attrs(station: "A", "origin" => df.attr("source"))
    df.column_names.each do |name|
      assert_equal({ "station" => "A", "origin" => "station network" }, df[name].attrs)
    end
  end

  def test_set_column_attrs_from_a_hash
    df = frame
    df.set_column_attrs(df.attrs)
    assert_equal ATTRS, df["k"].attrs
    df.set_column_attrs(df.attrs, title: "t")
    assert_equal "t", df["k"].attr("title")
    # an empty Hash sets nothing, not "name"
    df2 = other.set_column_attrs(other.attrs)
    assert_equal({}, df2["k"].attrs)
  end

  def test_set_column_attrs_on_named_columns
    df = frame
    df.set_column_attrs("v", long_name: "value")
    df.set_column_attrs("k", "g", station: "A")
    assert_equal({ "long_name" => "value" }, df["v"].attrs)
    assert_equal({ "station" => "A" }, df["k"].attrs)
    assert_equal({ "station" => "A" }, df["g"].attrs)
    assert_equal({}, df["s"].attrs)
    # named columns with no attributes take their names
    df.set_column_attrs("s")
    assert_equal({ "name" => "s" }, df["s"].attrs)
    assert_equal({}, df["t"].attrs)
    # "name" given explicitly is an attribute like any other
    df.set_column_attrs("t", name: "time")
    assert_equal "time", df["t"].attr("name")
  end

  def test_set_column_attrs_leaves_the_index_alone
    df = CAFrame.new({ "k" => CA_INT32([1, 2]), "v" => CA_FLOAT64([1, 2]) }).set_index("k")
    df.set_column_attrs
    assert_equal({}, df.index.attrs)
    assert_equal "v", df["v"].attr("name")
    e = assert_raise(KeyError) { df.set_column_attrs("k", a: 1) }
    assert_match(/\Aset_column_attrs: no column "k": it is the index/, e.message)
  end

  def test_set_column_attrs_refuses_before_writing
    df = frame
    assert_raise(KeyError) { df.set_column_attrs("v", "zz", a: 1) }
    assert_raise(TypeError) { df.set_column_attrs(:v, a: 1) }
    assert_raise(ArgumentError) { df.set_column_attrs("k", "k", a: 1) }
    assert_raise(TypeError) { df.set_column_attrs([1]) }
    assert_raise(TypeError) { df.set_column_attrs(a: 1, b: Object.new) }
    assert_raise(TypeError) { df.set_column_attrs(1 => "x") }
    df.column_names.each { |name| assert_equal({}, df[name].attrs) }
  end

  def test_set_column_attrs_with_a_frozen_column_writes_nothing
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([3, 4]).freeze)
    assert_raise(FrozenError) { df.set_column_attrs }
    assert_equal({}, df["a"].attrs)
  end

  # A name goes on a view that replaces the column, which a frozen frame
  # does not allow; attributes given still go on the columns, and a frame
  # named before it was frozen can name its own views again.
  def test_set_column_attrs_on_a_frozen_frame
    df = frame.freeze
    assert_raise(FrozenError) { df.set_column_attrs }
    df.set_column_attrs(units: "K")
    assert_equal "K", df["k"].attr("units")
    named = frame
    named.set_column_attrs
    named.freeze
    named.set_column_attrs
    assert_equal "k", named["k"].attr("name")
  end

  # A name is this frame's: frames sharing a column (rename, select, dup)
  # each show their own name, whichever names first, and a frame that names
  # nothing shows none. Attributes given reach every frame sharing the data.
  def test_a_name_stays_with_its_frame
    df = CAFrame.new("temp" => CA_FLOAT64([1, 2]))
    data = df["temp"]
    r = df.rename("temp" => "t2")
    r.set_column_attrs
    assert_nil df["temp"].attr("name")
    df.set_column_attrs
    assert_equal "temp", df["temp"].attr("name")
    assert_equal "t2", r["t2"].attr("name")
    assert_nil data.attr("name")
    df.select("temp").set_column_attrs(units: "K")
    assert_equal ["K", "K", "K"], [df["temp"], r["t2"], data].map { |c| c.attr("units") }
    df["temp"][0] = 9.0
    assert_equal [9.0, 2.0], data.to_a
  end

  # The same array under two names gets two names.
  def test_one_array_under_two_names
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]))
    df["z"] = df["x"]
    df.set_column_attrs
    assert_equal ["x", "z"], [df["x"].attr("name"), df["z"].attr("name")]
    view = df["x"]
    df.set_column_attrs
    assert_same view, df["x"]                  # its own view is named again, not wrapped
  end

  def test_marshal_round_trip
    assert_equal ATTRS, Marshal.load(Marshal.dump(frame)).attrs
  end

  # A loaded value is a frozen copy, as set_attr stores one.
  def test_marshal_round_trip_keeps_values_frozen
    df = frame
    df.set_attr(:note, "x")
    loaded = Marshal.load(Marshal.dump(df))
    assert_predicate loaded.attr(:note), :frozen?
  end

  def test_frame_and_column_attributes_are_separate
    df = frame
    df["v"].set_attr(:units, "m")
    assert_nil df.attr(:units)
    assert_nil df["k"].attr(:title)
  end

  # A splice edits this frame's table: each column and the index keep the
  # attributes they had, whether or not the rows put in carry any.
  def test_splice_keeps_the_columns_attributes
    a = CA_FLOAT64([1, 2, 3, 4])
    a.set_attr(:units, "K")
    idx = CA_INT32([1, 2, 3, 4])
    idx.set_attr(:units, "s")
    df = CAFrame.new({ "a" => a }, index: idx)
    o = CA_FLOAT64([9])
    o.set_attr(:extra, 1)
    df[0..0] = CAFrame.new({ "a" => o }, index: CA_INT32([9]))
    assert_equal({ "units" => "K" }, df["a"].attrs)
    assert_equal({ "units" => "s" }, df.index.attrs)
    assert_equal({ "extra" => 1 }, o.attrs)
  end
end
