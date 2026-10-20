require "test/unit"
require "carray"

# A write into a frozen array is Ruby's FrozenError, whichever method makes
# it.  A view of a frozen array is not frozen itself; a write through it is
# refused as a write into a read-only array, a RuntimeError.

class TestFrozenWrites < Test::Unit::TestCase

  def frozen_array
    CArray.float64(4).seq.freeze
  end

  def test_every_write_into_a_frozen_array_is_a_frozen_error
    idx = CA_INT64([0, 1])
    {
      "[]="          => ->(a) { a[0] = 1 },
      "fill"         => ->(a) { a.fill(1) },
      "map!"         => ->(a) { a.map! { |x| x } },
      "add!"         => ->(a) { a.add!(1) },
      "paste"        => ->(a) { a.paste([0], CA_FLOAT64([1])) },
      "mask="        => ->(a) { a.mask = 0 },
      "unmask"       => ->(a) { a.unmask(0) },
      "scatter_min!" => ->(a) { a.scatter_min!(idx, CA_FLOAT64([1, 1])) },
      "put_nd"       => ->(a) { a.put_nd(CA_INT64([[0]]), CA_FLOAT64([1])) },
      "elem_store"   => ->(a) { a.elem_store(0, 1) },
      "load_binary"  => ->(a) { a.load_binary("\0" * 32) },
    }.each do |name, write|
      a = frozen_array
      assert_raise(FrozenError, name) { write.(a) }
      assert_equal [0.0, 1.0, 2.0, 3.0], a.to_a, name
    end
  end

  def test_a_write_through_a_view_of_a_frozen_array_is_a_read_only_refusal
    a = frozen_array
    e = assert_raise(RuntimeError) { a[0..1][] = 1 }
    assert_not_kind_of FrozenError, e
    assert_raise(RuntimeError) { a.value[0] = 1 }
    assert_equal [0.0, 1.0, 2.0, 3.0], a.to_a
  end

end
