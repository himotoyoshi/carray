# CArray::AddressBasis.sweep runs the chunked slab family over arrays and
# hands the slab a table of pointers into the bytes of the Strings it was
# given -- without copying them out first.  That is sound only if no String
# moves while the sweep runs, and the sweep allocates, so a collection can
# run in the middle of it.  What makes it sound is that the parts arrive as
# arguments, on the VM stack, where an object is pinned.
#
# So the slab here is a Ruby block behind a Fiddle closure, and the first
# thing it does is the most thorough compaction Ruby has: every movable
# object is moved.  Then it compares where each part's bytes are now with
# the address it was handed.  A String held only by an Array is moved by
# the same compaction, which is what says the compaction was real.

require "test/unit"
require "carray"
require "fiddle"
require "fiddle/closure"

class TestAddressBasisSweep < Test::Unit::TestCase

  SLAB_ARGUMENTS = [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG,
                    Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP].freeze

  # out = a + reals[0], and the cell count written into the error slot.
  def adding_slab (parts, &inside)
    Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_VOID, SLAB_ARGUMENTS) do
      |base, stride, n, _mask, userdata|
      inside&.call(userdata)
      table = Fiddle::Pointer.new(userdata)[0, 8 * parts]
      pointers = table.unpack("Q*")
      bases = Fiddle::Pointer.new(base)[0, 16].unpack("Q2")
      strides = Fiddle::Pointer.new(stride)[0, 16].unpack("q2")
      real = Fiddle::Pointer.new(pointers[0])[0, 8].unpack1("d")
      n.times do |k|
        value = Fiddle::Pointer.new(bases[0] + k * strides[0])[0, 8].unpack1("d")
        Fiddle::Pointer.new(bases[1] + k * strides[1])[0, 8] = [value + real].pack("d")
      end
      counted = Fiddle::Pointer.new(pointers[1])[0, 8].unpack1("q")
      Fiddle::Pointer.new(pointers[1])[0, 8] = [counted + n].pack("q")
    end
  end

  def test_the_slab_reads_and_writes_the_parts_it_is_handed
    a = CArray.double(10).seq!
    out = CArray.double(10)
    reals = [0.5].pack("d").freeze
    counted = [0].pack("q")
    slab = adding_slab(2)
    CArray::AddressBasis.sweep(slab.to_i, "01", [a, out], reals, counted)
    assert_equal (0...10).map { |i| i + 0.5 }, out.to_a
    assert_equal 10, counted.unpack1("q")
  end

  def test_no_part_moves_while_the_sweep_runs
    a = CArray.double(10).seq!
    out = CArray.double(10)
    # Short enough to be embedded, which is the case where the bytes are
    # inside the object and move with it.
    reals = [0.5].pack("d").freeze
    counted = [0].pack("q")
    held = [[1.0].pack("d")]
    held_before = Fiddle::Pointer[held[0]].to_i
    moved = nil
    slab = adding_slab(2) do |userdata|
      next unless moved.nil?
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      pointers = Fiddle::Pointer.new(userdata)[0, 16].unpack("Q2")
      moved = {
        reals: Fiddle::Pointer[reals].to_i != pointers[0],
        counted: Fiddle::Pointer[counted].to_i != pointers[1],
        held: Fiddle::Pointer[held[0]].to_i != held_before,
      }
    end
    CArray::AddressBasis.sweep(slab.to_i, "01", [a, out], reals, counted)
    assert moved[:held], "the compaction moved nothing, so it proves nothing"
    assert_equal false, moved[:reals]
    assert_equal false, moved[:counted]
    assert_equal (0...10).map { |i| i + 0.5 }, out.to_a
    assert_equal 10, counted.unpack1("q")
  end

  def test_a_shared_part_is_unshared_before_the_slab_writes_it
    a = CArray.double(4).seq!
    out = CArray.double(4)
    reals = [0.0].pack("d").freeze
    original = [0].pack("q") * 4
    counted = original[0, 8]
    slab = adding_slab(2)
    CArray::AddressBasis.sweep(slab.to_i, "01", [a, out], reals, counted)
    assert_equal 4, counted.unpack1("q")
    assert_equal [0, 0, 0, 0], original.unpack("q*")
  end

  def test_what_it_refuses
    a = CArray.double(4)
    slab = adding_slab(2)
    assert_raise(ArgumentError) { CArray::AddressBasis.sweep(slab.to_i, "0", [a, a]) }
    assert_raise(ArgumentError) { CArray::AddressBasis.sweep(slab.to_i, "0" * 8, [a] * 8) }
    assert_raise(ArgumentError) { CArray::AddressBasis.sweep(0, "0", [a]) }
    assert_raise(TypeError) { CArray::AddressBasis.sweep(slab.to_i, "0", [[1.0]]) }
    # The tail of a long String shares its bytes, one byte in.  (A slice
    # that stops short is copied, and lands aligned.)
    misaligned = ("\0" * 128)[1..].freeze
    assert_not_equal 0, Fiddle::Pointer[misaligned].to_i & 7
    assert_raise(ArgumentError) {
      CArray::AddressBasis.sweep(slab.to_i, "0", [a], misaligned)
    }
  end

end
