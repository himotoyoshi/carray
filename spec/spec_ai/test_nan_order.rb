require 'test/unit'
require 'carray'

# Sort and every order statistic put a NaN after every number, NaN ties
# NaN, in both directions; masked cells are outside the order.  Each case
# is answered twice: over data with NaN, and over the same data with each
# NaN replaced by a finite value past every number (or before every number
# for a descending order, where NaN still comes last).  Read back, the two
# must agree everywhere.
class TestNanOrder < Test::Unit::TestCase

  NAN = Float::NAN

  def self.values (rows, cols)
    Array.new(rows) { |i| Array.new(cols) { |j| ((i * 7 + j * 3) % 5) - 2.0 } }.tap do |v|
      v[0][1] = NAN; v[1][3] = NAN; v[2][0] = NAN; v[2][4] = NAN
      v[rows - 1][cols - 1] = NAN
    end
  end

  # The stand-in for NaN, and the bound past which a value reads back as NaN.
  def self.big (data_type)
    data_type == :float32 ? 3e38 : 1e300
  end

  def self.build (data_type, vals, sentinel)
    flat = vals.flatten.map { |x| (x.is_a?(Float) && x.nan? && sentinel) ? sentinel : x }
    a = CArray.new(data_type, [vals.size, vals[0].size])
    a[] = CA_OBJECT(flat).reshape(*a.shape)
    a
  end

  def self.input (data_type, kind, sentinel)
    v = values(4, 6)
    case kind
    when :entity    then build(data_type, v, sentinel)
    when :transpose then build(data_type, v.transpose, sentinel).transpose
    when :lazy      then build(data_type, v, sentinel).lazy + 0
    when :masked
      a = build(data_type, v, sentinel)
      a[1, 1] = UNDEF
      a[3, 2] = UNDEF
      a
    end
  end

  def self.read (x, bound)
    case x
    when CArray then [x.shape, x.to_a.flatten.map { |e| read(e, bound) }]
    when Array  then x.map { |e| read(e, bound) }
    when Float  then (x.nan? || x.abs >= bound) ? :nan : x.round(9)
    else x
    end
  end

  # name => [direction, op]; direction -1 is a descending order.
  OPS = {}
  [nil, 0, 1].each do |ax|
    [:quick, :stable].each do |k|
      [:last, :first].each do |mp|
        kw = { axis: ax, kind: k, masked_position: mp }
        OPS["sort #{kw}"]       = [1, ->(a) { a.sort(**kw) }]
        OPS["sort_copy #{kw}"]  = [1, ->(a) { a.sort_copy(**kw) }]
        OPS["sort_index #{kw}"] = [1, ->(a) { a.sort_index(**kw) }]
        OPS["sort_addr #{kw}"]  = [1, ->(a) { a.sort_addr(**kw) }]
      end
    end
    [false, true].each do |d|
      [:ordinal, :dense].each do |m|
        OPS["order axis=#{ax} descending=#{d} #{m}"] =
          [d ? -1 : 1, ->(a) { a.order(axis: ax, descending: d, method: m) }]
      end
    end
    OPS["rank_index axis=#{ax}"] = [1, ->(a) { a.rank_index(axis: ax) }]
    [0, 3, 5].each do |kth|
      at = ->(r) { ax.nil? ? r[kth] : (ax == 0 ? r[[kth, 3].min, nil] : r[nil, kth]) }
      kk = ax == 0 ? [kth, 3].min : kth
      OPS["partition #{kk} axis=#{ax}"]      = [1, ->(a) { at.(a.partition(kk, axis: ax)) }]
      OPS["partition_copy #{kk} axis=#{ax}"] = [1, ->(a) { at.(a.partition_copy(kk, axis: ax)) }]
    end
    OPS["partition_index 23 -> value"] = [1, ->(a) { a.flatten[a.partition_index(23)[23]] }]
    OPS["median axis=#{ax}"]              = [1, ->(a) { a.median(axis: ax) }]
    OPS["percentile 10 50 90 axis=#{ax}"] = [1, ->(a) { a.percentile(10, 50, 90, axis: ax) }]
    OPS["quantile axis=#{ax}"]            = [1, ->(a) { a.quantile(axis: ax) }]
    [1, 3, 5].each do |n|
      OPS["nlargest #{n} axis=#{ax}"]        = [-1, ->(a) { a.nlargest(n, axis: ax) }]
      OPS["nsmallest #{n} axis=#{ax}"]       = [1,  ->(a) { a.nsmallest(n, axis: ax) }]
      next if ax.nil?   # the index forms take an axis
      OPS["nlargest_index #{n} axis=#{ax}"]  = [-1, ->(a) { a.nlargest_index(n, axis: ax) }]
      OPS["nsmallest_index #{n} axis=#{ax}"] = [1,  ->(a) { a.nsmallest_index(n, axis: ax) }]
    end
  end
  OPS["sort_by_key"]           = [1, ->(a) { CArray.int64(24).seq!.sort_by_key(a.flatten) }]
  OPS["unique sort"]           = [1, ->(a) { a.unique(sort: true) }]
  OPS["value_counts by value"] = [1, ->(a) { a.value_counts(sort: :value) }]
  OPS["mode"]                  = [1, ->(a) { a.mode }]
  OPS["is_mode"]               = [1, ->(a) { a.is_mode }]
  # the search family takes a sorted array without masked cells
  sorted = ->(a) { s = a.sort.copy; s[0...a.count_not_masked].copy }
  [1.0, 1.4, 1e9, NAN].each do |q|
    OPS["bsearch #{q}"]             = [1, ->(a) { sorted.(a).bsearch(q) }]
    OPS["bsearch_addr #{q}"]        = [1, ->(a) { sorted.(a).bsearch_addr(q) }]
    OPS["search #{q}"]              = [1, ->(a) { a.search(q) }]
    OPS["search_addr #{q}"]         = [1, ->(a) { a.search_addr(q) }]
    OPS["search_nearest #{q}"]      = [1, ->(a) { sorted.(a).search_nearest(q) }]
    OPS["search_nearest_addr #{q}"] = [1, ->(a) { sorted.(a).search_nearest_addr(q) }]
  end
  OPS["CArray.sort_addr key, x"] = [1, ->(a) { CArray.sort_addr(CArray.int64(24) { |i| i % 3 }, a.flatten) }]
  OPS["CArray.sort_addr x, key"] = [1, ->(a) { CArray.sort_addr(a.flatten, CArray.int64(24) { |i| i % 3 }) }]

  def answer (op, data_type, kind, sentinel)
    self.class.read(op.call(self.class.input(data_type, kind, sentinel)),
                    self.class.big(data_type) / 10)
  rescue StandardError => e
    "#{e.class}: #{e.message}"
  end

  def test_every_order_puts_nan_after_the_numbers
    wrong = []
    raised = []
    %i[float64 float32 object].each do |dt|
      %i[entity transpose lazy masked].each do |kind|
        OPS.each do |name, (dir, op)|
          got = answer(op, dt, kind, nil)
          ref = answer(op, dt, kind, dir * self.class.big(dt))
          raised << "#{dt} #{kind} #{name}: #{got}" if got.is_a?(String)
          wrong << "#{dt} #{kind} #{name}" unless got == ref
        end
      end
    end
    assert_equal [], wrong
    assert_equal [], raised
  end

  # The iterator family and CAFrame order through the core.
  ITERATORS = {
    CACategoricalIterator => {
      "median"     => ->(a, k) { a.group_by_category(k).median },
      "percentile" => ->(a, k) { a.group_by_category(k).percentile(90) },
      "quantile"   => ->(a, k) { a.group_by_category(k).quantile },
      "axis 1"     => ->(a, k) { a.group_by_category(CA_INT32([0, 1, 2, 0, 1, 2]).categorize).median(axis: 1) },
    },
    CAGroupIterator => {
      "median"     => ->(a, k) { a[CA_INT32([0, 0, 1, 1]).categorize, nil].median(axis: :group) },
      "percentile" => ->(a, k) { a[CA_INT32([0, 0, 1, 1]).categorize, nil].percentile(90, axis: :group) },
      "quantile"   => ->(a, k) { a[CA_INT32([0, 0, 1, 1]).categorize, nil].quantile(axis: :group) },
    },
    CAWindowIterator => {
      "median"     => ->(a, k) { a.windows(-1..1, -1..1).median },
      "percentile" => ->(a, k) { a.windows(0..0, -1..1).percentile(90) },
    },
    CAKeyWindowIterator => {
      "median"     => ->(a, k) { a.flatten.windows(on: CArray.int64(24).seq!, before: 2, after: 1).median },
      "percentile" => ->(a, k) { a.flatten.windows(on: CArray.int64(24).seq!, before: 2, after: 1).percentile(90) },
    },
    CABlockIterator => {
      "median"     => ->(a, k) { a.blocks(2, 3).median },
      "percentile" => ->(a, k) { a.blocks(2, 3).percentile(25, 90) },
      "quantile"   => ->(a, k) { a.blocks(2, 3).quantile },
    },
    CASegmentIterator => {
      "median"     => ->(a, k) { a.flatten.segments(lengths: [5, 7, 12]).median },
      "percentile" => ->(a, k) { a.flatten.segments(lengths: [5, 7, 12]).percentile(90) },
    },
    CASlabIterator => {
      "median"     => ->(a, k) { CASlabIterator.new(a, [1]).median },
    },
  }

  def test_every_iterator_orders_as_the_core
    key = CA_INT32((0...24).map { |i| i % 3 }).reshape(4, 6).categorize
    wrong = []
    %i[float64 float32 object].each do |dt|
      %i[entity masked].each do |kind|
        ITERATORS.each do |klass, ops|
          ops.each do |name, op|
            f = ->(a) { op.call(a, key) }
            got = answer(f, dt, kind, nil)
            ref = answer(f, dt, kind, self.class.big(dt))
            wrong << "#{dt} #{kind} #{klass} #{name}: #{got.inspect[0, 80]}" unless got == ref && !got.is_a?(String)
          end
        end
      end
    end
    assert_equal [], wrong
  end

  def test_frame_sorts_and_groups_as_the_core
    wrong = []
    %i[float64 object].each do |dt|
      [[1, ->(x) { CAFrame.new("x" => x, "k" => CArray.int64(24) { |i| i % 3 }).sort_by_key("x")["k"] }],
       [-1, ->(x) { CAFrame.new("x" => x, "k" => CArray.int64(24) { |i| i % 3 }).sort_by_key("x", descending: true)["k"] }],
       [1, ->(x) { CAFrame.new("x" => x, "k" => CArray.int64(24) { |i| i % 3 }).group_by("k").median["x"] }]].each_with_index do |(dir, op), i|
        f = ->(a) { op.call(a.flatten) }
        got = answer(f, dt, :entity, nil)
        ref = answer(f, dt, :entity, dir * self.class.big(dt))
        wrong << "#{dt} #{i}" unless got == ref && !got.is_a?(String)
      end
    end
    assert_equal [], wrong
  end

  # Two Ruby values are ordered as two cells are sorted.
  def test_ruby_values_order_as_cells_sort
    labels = CA_OBJECT([NAN, 2, 1.5, NAN, 1]).categorize(sort_labels: true).labels.to_a
    assert_equal [1, 1.5, 2], labels[0, 3]
    assert_equal true, labels[3].nan?
    labels = CA_FLOAT64([NAN, 2, 1, NAN]).categorize(sort_labels: true).labels.to_a
    assert_equal [1.0, 2.0], labels[0, 2]
    assert_equal true, labels[2].nan?

    st = CArray.struct(order_by: [:x]) { float64 :x }
    nan, one = st.new(x: NAN), st.new(x: 1.0)
    assert_equal [1, -1, 0], [nan <=> one, one <=> nan, nan <=> st.new(x: NAN)]
    recs = CARecord.new(st, 3)
    recs[0] = nan; recs[1] = st.new(x: 2.0); recs[2] = one
    assert_equal [2, 1, 0], recs.sort_index.to_a
  end

  # The tables above are every order method there is: a new one has to be
  # added to them, or here with the reason it is not.
  NOT_ORDERS = {
    rank: "the deprecated ndim",
    bsearch_ki: "the kernel bsearch calls", bsearch_addr_ki: "the kernel bsearch_addr calls",
    search_ki: "the kernel search calls", search_addr_ki: "the kernel search_addr calls",
    search_nearest_ki: "the kernel search_nearest calls",
    search_nearest_addr_ki: "the kernel search_nearest_addr calls",
    sort_index_ki: "the kernel sort_index calls", rank_index_ki: "the kernel rank_index calls",
    partition_index_ki: "the kernel partition_index calls",
  }
  ORDER_NAME = /\A(sort|order|rank|partition|median|percentile|quantile|nlargest|nsmallest|bsearch|search|unique|mode|value_counts|is_mode)/

  def test_every_order_method_is_measured
    covered = OPS.keys.map { |k| k[/\A[\w.]+/] }.uniq.map(&:to_sym)
    found = CArray.public_instance_methods(true).grep(ORDER_NAME)
    assert_equal [], (found - covered - NOT_ORDERS.keys).sort
    Object.constants.grep(/Iterator\z/).each { |c| Object.const_get(c) }
    iterators = ObjectSpace.each_object(Class).select { |c|
      c < CAIterator && %i[median percentile quantile].any? { |m| c.public_method_defined?(m) }
    }
    assert_equal [], (iterators - ITERATORS.keys).map(&:name).sort
  end
end
