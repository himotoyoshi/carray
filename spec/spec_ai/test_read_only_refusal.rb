# frozen_string_literal: true
#
# A write into a read-only array that is not frozen raises RuntimeError
# "<method>: can not modify read-only array", whatever made it read-only (a
# lazy node or a view of one, a CAConstString, a view of a frozen array, a
# stack holding a read-only part) and whichever way the write comes (a
# store, a fill, a bang operator, masking a cell).  A frozen array raises
# Ruby's FrozenError.
#
# The refusal is one part, ca_refuse_read_only.  The guards below the entry
# points had their own wording ("can not store data to read-only array",
# "CABinOp is read-only (xfer_index PUT)") and none named the method.

require "test/unit"
require "carray"

class TestReadOnlyRefusal < Test::Unit::TestCase

  def base
    CA_INT32([1, 2, 3, 4])
  end

  def read_only_arrays
    {
      "a lazy node"           => (base.lazy + 1),
      "a view of a lazy node" => (base.lazy + 1)[1..2],
      "a lazy comparison"     => base.lazy.gt(1),
      "a CAConstString"       => CArray.const_string(%w[a b c d]),
      "a view of a frozen"    => base.freeze[1..2],
      "a stack with one"      => CArray.stack([base.lazy + 1, base]),
    }
  end

  WRITES = {
    "[]="  => ->(a) { a[0] = 9 },
    "fill" => ->(a) { a.fill(9) },
    "add!" => ->(a) { a.add!(1) },
  }.freeze

  def test_every_write_into_every_read_only_array
    read_only_arrays.each do |kind, a|
      WRITES.each do |name, write|
        e = assert_raise(RuntimeError, "#{kind} #{name}") { write.(a) }
        assert_equal "#{name}: can not modify read-only array", e.message, "#{kind} #{name}"
      end
      e = assert_raise(RuntimeError, "#{kind} mask") { a[0] = UNDEF }
      assert_equal "[]=: can not modify read-only array", e.message, "#{kind} mask"
    end
  end

  def test_a_frozen_array_is_ruby_s_frozen_error
    assert_raise(FrozenError) { base.freeze[0] = 9 }
    assert_raise(FrozenError) { base.freeze.fill(9) }
  end

end
