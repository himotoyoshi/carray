# A value stored into an integer cell must fit the cell's type; one that does
# not raises RangeError, as an operator refuses it.  Every store path reads
# the value the same way: building from an Array, a single cell, a whole
# array, an Array into an array, fill, elem_store and the selector forms.  An array cast (to_type) keeps the
# C conversion.

require "test/unit"
require "carray"

class TestStoreIntegerRange < Test::Unit::TestCase

  RANGES = {
    int8:   [-2**7,  2**7 - 1],  uint8:  [0, 2**8 - 1],
    int16:  [-2**15, 2**15 - 1], uint16: [0, 2**16 - 1],
    int32:  [-2**31, 2**31 - 1], uint32: [0, 2**32 - 1],
    int64:  [-2**63, 2**63 - 1], uint64: [0, 2**64 - 1],
  }

  STORES = {
    "CA_T([v])" => ->(t, v) { Object.send(:"CA_#{t.to_s.upcase}", [v])[0] },
    "a[0] = v"  => ->(t, v) { a = CArray.send(t, 1); a[0] = v; a[0] },
    "a[] = v"   => ->(t, v) { a = CArray.send(t, 1); a[] = v; a[0] },
    "a[] = [v]" => ->(t, v) { a = CArray.send(t, 1); a[] = [v]; a[0] },
    "fill(v)"   => ->(t, v) { CArray.send(t, 1).fill(v)[0] },
    "elem_store" => ->(t, v) { a = CArray.send(t, 1); a.elem_store(0, v); a[0] },
    "a[bool] = v" => ->(t, v) { a = CArray.send(t, 1); a[CA_BOOLEAN([1])] = v; a[0] },
    "a[[0]] = v"  => ->(t, v) { a = CArray.send(t, 1); a[[0]] = v; a[0] },
  }

  def test_every_integer_type_is_listed
    integer_types = Object.constants.grep(/\ACA_U?INT\d+\z/).map { |c| c.to_s.sub("CA_", "").downcase.to_sym }
    assert_equal integer_types.sort, RANGES.keys.sort
  end

  def test_values_that_fit_are_stored
    RANGES.each do |t, (lo, hi)|
      STORES.each do |name, store|
        [lo, hi, 0, 1].each do |v|
          assert_equal v, store.(t, v), "#{t} #{name} #{v}"
        end
      end
    end
  end

  def test_values_that_do_not_fit_raise
    RANGES.each do |t, (lo, hi)|
      STORES.each do |name, store|
        [lo - 1, hi + 1].each do |v|
          assert_raise(RangeError, "#{t} #{name} #{v}") { store.(t, v) }
        end
      end
    end
  end

  def test_a_float_is_truncated_then_checked
    assert_equal 1, CA_INT8([1.9])[0]
    assert_equal 127, CA_INT8([127.5])[0]
    assert_raise(RangeError) { CA_INT8([1000.0]) }
    assert_raise(RangeError) { CA_UINT8([-1.0]) }
  end

  # A record member is a cell too.
  def test_record_members_refuse_what_does_not_fit
    s = CArray.struct { int8 :a; uint16 :b; int32 :c; uint64 :d }
    assert_equal 127, s.new(a: 127).a
    assert_raise(RangeError) { s.new(a: 300) }
    assert_raise(RangeError) { s.new(b: -1) }
    assert_raise(RangeError) { s.new(c: 2**40) }
    assert_raise(RangeError) { s.new(d: -1) }
    e = s.new
    assert_raise(RangeError) { e.a = 300 }
  end

  # An array cast is not a store.
  def test_to_type_keeps_the_c_conversion
    assert_equal [44, -1], CA_OBJECT([300, -1]).to_type(:int8).to_a
    assert_equal [255],    CA_OBJECT([-1]).to_type(:uint8).to_a
    assert_equal [44],     CA_INT32([300]).to_type(:int8).to_a
  end

end
