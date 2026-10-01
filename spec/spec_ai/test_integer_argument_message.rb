require "test/unit"
require "carray"

# min_count:, kth and n follow the rule of axis: an Integer or a TypeError,
# and errors name the method the user called.  One row per path that reads
# the argument: the generated reductions, median / percentile, the windows
# fold, the generated partition kernels, partition_copy (and its masked
# path, which hands off to partition), and the top-k family.
class TestIntegerArgumentMessage < Test::Unit::TestCase

  A = CArray.float64(3, 4).seq
  M = CArray.int32(3, 4).seq.tap { |x| x[0, 0] = UNDEF }

  MIN_COUNT = {
    "sum"        => ->(v) { A.sum(axis: 1, min_count: v) },
    "count"      => ->(v) { (A > 5).count(true, axis: 1, min_count: v) },
    "median"     => ->(v) { A.median(axis: 1, min_count: v) },
    "percentile" => ->(v) { A.percentile(50, axis: 1, min_count: v) },
    "windows"    => ->(v) { A.windows(-1..1, -1..1).sum(min_count: v) },
  }

  KTH = {
    "partition"       => ->(v) { A.partition(v, axis: 1) },
    "partition_index" => ->(v) { A.partition_index(v, axis: 1) },
    "partition_copy"  => ->(v) { A.partition_copy(v, axis: 1) },
    "masked partition_copy" => ->(v) { M.partition_copy(v, axis: 1) },
  }

  N = {
    "nlargest"        => ->(v) { A.nlargest(v, axis: 1) },
    "nsmallest_index" => ->(v) { A.nsmallest_index(v, axis: 1) },
  }

  def method_name (label)
    label == "windows" ? "sum" : label.sub("masked ", "")
  end

  MIN_COUNT.each do |label, call|
    define_method("test_min_count_#{label}") do
      name = method_name(label)
      err = assert_raise(TypeError) { call.(1.5) }
      assert_equal "#{name}: min_count must be an Integer (got Float)", err.message
      err = assert_raise(ArgumentError) { call.(-1) }
      assert_equal "#{name}: min_count must be non-negative (got -1)", err.message
      assert_equal call.(0).to_a, call.(nil).to_a       # nil is the default
    end
  end

  KTH.each do |label, call|
    define_method("test_kth_#{label.tr(" ", "_")}") do
      name = method_name(label)
      err = assert_raise(TypeError) { call.(1.5) }
      assert_equal "#{name}: kth must be an Integer (got Float)", err.message
      [4, -5].each do |k|
        err = assert_raise(ArgumentError) { call.(k) }
        assert_equal "#{name}: kth #{k} out of range for length 4", err.message
      end
    end
  end

  N.each do |label, call|
    define_method("test_n_#{label}") do
      err = assert_raise(TypeError) { call.(1.5) }
      assert_equal "#{label}: n must be an Integer (got Float)", err.message
      err = assert_raise(ArgumentError) { call.(-1) }
      assert_equal "#{label}: n must be non-negative (got -1)", err.message
    end
  end

end
