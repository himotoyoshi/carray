# frozen_string_literal: true
#
# An axis is an Integer in [-ndim, ndim): negative counts from the end, any
# other Integer raises ArgumentError naming the value given, anything else
# raises TypeError.  ndim is at most CA_RANK_MAX, so how wide an Integer is
# does not matter -- a value past int, past long, a Bignum, is out of range
# like 5 is.
#
# Before, several entries narrowed the argument to an int before comparing
# it, and 2**32 + 1 came out as 1: cumsum, sort_addr, bsearch, insert_axis
# and the slab iterators answered silently on axis 1.  A Bignum raised
# RangeError from the conversion, naming no method.  join read its axis with
# Integer(), so 1.5 and "1" were taken as axis 1.

require "test/unit"
require "carray"

class TestAxisBeyondInt < Test::Unit::TestCase

  A = CArray.int32(2, 3) { |i, j| i * 3 + j }

  ENTRIES = {
    "normalize_axis"  => ->(x) { A.normalize_axis(x) },
    "sum"             => ->(x) { A.sum(axis: x) },
    "cumsum"          => ->(x) { A.cumsum(axis: x) },
    "sort"            => ->(x) { A.sort(axis: x) },
    "sort_addr"       => ->(x) { A.sort_addr(axis: x) },
    "bsearch"         => ->(x) { A.bsearch(1, axis: x) },
    "partition_copy"  => ->(x) { A.partition_copy(1, axis: x) },
    "take_along_axis" => ->(x) { A.take_along_axis(A.sort_index(axis: 1), axis: x) },
    "median"          => ->(x) { A.median(axis: x) },
    "flip"            => ->(x) { A.flip(x) },
    "dim_view"        => ->(x) { A.dim_view(x) },
    "diagonal"        => ->(x) { A.diagonal(axis: [x, 0]) },
    "insert_axis"     => ->(x) { A.insert_axis(x) },
    "each_slab"       => ->(x) { A.each_slab(axis: x) { } },
    "map_slab"        => ->(x) { A.map_slab(axis: x) { |s| s } },
    "first"           => ->(x) { A.first(axis: x) },
    "shuffle"         => ->(x) { A.shuffle(axis: x) },
    "seq!"            => ->(x) { A.copy.seq!(axis: x) },
    "join"            => ->(x) { A.join(",", axis: x) },
    "stack"           => ->(x) { CArray.stack([A, A], axis: x) },
    "meld"            => ->(x) { CArray.meld([A, A], axis: x) },
  }.freeze

  WIDE = [2**31, 2**32 + 1, -(2**32) + 1, 2**63, 2**70].freeze

  def test_a_wide_integer_is_out_of_range_everywhere
    ENTRIES.each do |name, call|
      WIDE.each do |x|
        e = assert_raise(ArgumentError, "#{name}(#{x})") { call.(x) }
        assert_match(/: axis #{x} out of range for ndim \d+\z/, e.message,
                     "#{name}(#{x})")
      end
    end
  end

  def test_the_message_names_the_method_and_the_value
    ENTRIES.each do |name, call|
      e = assert_raise(ArgumentError, name) { call.(5) }
      assert_match(/\A#{Regexp.escape(name)}: axis 5 out of range for ndim \d+\z/,
                   e.message, name)
    end
  end

  def test_a_non_integer_is_a_type_error
    ENTRIES.each do |name, call|
      [1.5, "1"].each do |x|
        assert_raise(TypeError, "#{name}(#{x.inspect})") { call.(x) }
      end
    end
  end

  def test_an_axis_in_range_still_answers
    assert_equal ["0,1,2", "3,4,5"], A.join(",", axis: 1).to_a
    assert_equal A.flip(1).to_a, A.flip(-1).to_a
    assert_equal [2, 1, 3], A.insert_axis(-2).shape
    assert_equal [0, 4], A.diagonal(axis: [-2, -1]).to_a
  end

end
