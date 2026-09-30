# spec_ai/test_constructor_raise_cleanup.rb
#
# A constructor that rejects its arguments raises before it allocates the
# array's struct, so the raise leaves nothing behind.  What used to leak
# was the struct and its shape arrays: 80 to 900 bytes.  The threshold is
# 40 bytes per call over 10000 calls, measured by utils/measure_leak.rb
# (macOS only); a bare `raise` measures under 1.
#
# A shape with more entries than the rank limit is also rejected before it
# is copied into the fixed-size work array.

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestConstructorRaiseCleanup < Test::Unit::TestCase

  A16 = "a = CArray.int32(*[1]*16)"
  Z16 = "a = CArray.int32(*[1]*15, 0)"

  CASES = {
    as_strided_negative_dim: ["a = CArray.int32(4)", "a.as_strided(shape: [1]*15+[-1], strides: [4]*16)"],
    transpose_duplicate:     [A16, "a.transpose(*[0]*16)"],
    field_out_of_range:      ["a = CArray.int32(4)", "a.field(0, :int64)"],
    refer_too_large:         ["a = CArray.int32(4)", "a.refer(:int32, [1]*15+[8])"],
    refer_rank_over_limit:   ["a = CArray.int32(4)", "a.refer(:int32, [1]*40)"],
    repeat_ndim_mismatch:    ["a = CArray.int32(3)", "a[*[2]*15, :%, :%]"],
    repeat_rank_over_limit:  ["a = CArray.int32(3)", "a[*[2]*16, :%]"],
    window_empty:            [A16, "a.window(*[0..0]*15, 0...0)"],
    shift_empty_axis:        [Z16, "a.shift(*[1]*16)"],
    tile_zero_reps:          [A16, "a.tile(*[1]*15+[0])"],
    roll_empty_axis:         [Z16, "a.roll(*[1]*16)"],
    bitfield_out_of_range:   ["a = CArray.int32(8)", "a.bitfield(100)"],
    bitarray_of_complex:     ["a = CArray.cmplx128(4)", "a.bitarray"],
    string_of_int:           ["a = CArray.int32(8)", "CAString.wrap(a)"],
    fixlen_string_of_int:    ["a = CArray.int32(8)", "CAFixlenString.wrap(a)"],
    time_of_int32:           ["a = CArray.int32(8)", "CATime.__wrap__(a, :s)"],
    endian_of_object:        ["a = CArray.object(3)", "a.endian(:big)"],
    empty_negative_dim:      ["a = nil", "CArray.empty(:int32, [-1])"],
    empty_too_large:         ["a = nil", "CArray.empty(:int32, [1<<40, 1<<40])"],
    template_too_large:      ["a = CArray.int32(8)", "a.template(:fixlen, bytes: 1<<62)"],
    new_rank_over_limit:     ["a = nil", "CArray.new(:int32, [1]*60)"],
  }

  CASES.each do |name, (setup, expr)|
    define_method("test_#{name}") do
      assert_raise_kind_of(StandardError) { eval("#{setup}; #{expr}") }
      bytes = LeakMeter.bytes_per_call(expr, setup: setup, calls: 10000)
      omit "malloc zone statistics unavailable" if bytes.nil?
      assert_operator bytes, :<, 40,
                      "#{expr}: the malloc zone grew #{bytes.round(1)} bytes per call"
    end
  end

end
