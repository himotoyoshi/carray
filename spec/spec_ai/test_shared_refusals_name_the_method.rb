# frozen_string_literal: true
#
# A refusal raised by a part that many methods share opens with the method
# the user called, as the rest do: "<method>: ...".
#
# These parts said what was wrong but not where: a shape mismatch between
# operands or in a store, a negative size, a data type id or name that is
# not one, a fixlen without bytes, an index that is not one, a value that
# cannot be read as the cell's type, a binary of the wrong size.  The name is
# found from the frames (ca_calling_method_name), so a part needs nothing
# from its callers to say it.

require "test/unit"
require "carray"

class TestSharedRefusalsNameTheMethod < Test::Unit::TestCase

  A = CA_INT32([1, 2, 3])
  X = CA_INT32([1, 2])

  def assert_named (name, klass = ArgumentError, &block)
    e = assert_raise(klass, name, &block)
    assert e.message.start_with?("#{name}: "), "#{name}: #{e.message}"
  end

  def test_a_shape_mismatch_between_operands
    assert_named("+")         { A + X }
    assert_named("eq")        { A.eq(X) }
    assert_named("pmax")      { A.pmax(X) }
    assert_named("then_else") { CA_BOOLEAN([1, 0, 1]).then_else(A, X) }
  end

  def test_a_shape_mismatch_in_a_store
    assert_named("[]=") { A.copy[] = X }
  end

  def test_a_shape_or_a_type_that_is_not_one
    assert_named("int32")   { CArray.int32(-1) }
    assert_named("new")     { CArray.new(:nope, [3]) }
    assert_named("to_type") { A.to_type(:nope) }
    assert_named("to_type") { A.to_type(99) }
    assert_named("fixlen")  { CArray.fixlen(3, bytes: 0) }
  end

  def test_an_index_or_a_value_that_cannot_be_read
    assert_named("[]", IndexError) { A[1.5] }
    assert_named("fill")           { A.copy.fill("x") }
    assert_named("load_binary")    { A.copy.load_binary("ab") }
  end

end
