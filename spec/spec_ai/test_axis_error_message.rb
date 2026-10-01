require "test/unit"
require "carray"

# An out-of-range axis is reported under the method the user called, with
# the value the user passed (not the value after adding ndim).  One row per
# path that builds the message: the reduction parser, a generated kernel
# reached from C, a generated kernel reached through a Ruby wrapper, a C
# entry shared by two methods, the Ruby-side helpers, and the slab parser.
class TestAxisErrorMessage < Test::Unit::TestCase

  A = CArray.float64(3, 4).seq
  M = CArray.float64(3, 4).seq.tap { |x| x[1, 2] = UNDEF }

  CASES = {
    "sum"             => ->(ax) { A.sum(axis: ax) },
    "min_index"       => ->(ax) { A.min_index(axis: ax) },
    "cumsum"          => ->(ax) { A.cumsum(axis: ax) },
    "sort"            => ->(ax) { A.sort(axis: ax) },
    "sort_index"      => ->(ax) { A.sort_index(axis: ax) },
    "partition"       => ->(ax) { A.partition(1, axis: ax) },
    "bsearch"         => ->(ax) { A.bsearch(5.0, axis: ax) },
    "percentile"      => ->(ax) { A.percentile(50, axis: ax) },
    "quantile"        => ->(ax) { A.quantile(axis: ax) },
    "take_along_axis" => ->(ax) { A.take_along_axis(CArray.int64(3, 4), axis: ax) },
    "axis2addr"       => ->(ax) { A.axis2addr(CArray.int64(3, 4), axis: ax) },
    "shuffle"         => ->(ax) { A.copy.shuffle(axis: ax) },
    "concatenate"     => ->(ax) { CArray.concatenate([A, A], axis: ax) },
    "unmask"          => ->(ax) { M.copy.unmask(method: :linear, axis: ax) },
    "strip_mask"      => ->(ax) { M.strip_mask(method: :forward, axis: ax) },
    "each_slab"       => ->(ax) { A.each_slab(axis: ax) { } },
    "normalize_axis"  => ->(ax) { A.normalize_axis(ax) },
  }

  CASES.each do |name, call|
    define_method("test_#{name}") do
      [2, -3].each do |ax|
        err = assert_raise(ArgumentError, IndexError) { call.(ax) }
        assert_equal "#{name}: axis #{ax} out of range for ndim 2", err.message
      end
    end
  end

end
