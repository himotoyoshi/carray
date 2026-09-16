require "test/unit"
require "carray"

# `jit_for`, `jit_each` and `jit_map` are the carray-jit gem's: it defines the
# language their block is written in, and CArray holds none of their names.
class TestJitNamesAbsent < Test::Unit::TestCase

  def test_they_are_not_named_here
    omit "carray-jit is loaded in this process" if defined?(CArray::JIT)
    assert_false CArray.respond_to?(:jit_for)
    assert_false CArray.respond_to?(:jit_each)
    assert_false CArray.respond_to?(:jit_map)
  end

  def test_the_interpreted_forms_are_gone
    # They ran the block as an ordinary Ruby loop, which meant the same
    # program was a hundred times slower with the gem absent and, worse,
    # accepted blocks the compiler refuses -- so installing the compiler
    # could break a program that ran without it.
    assert_false CArray.respond_to?(:per_cell)
    assert_false CArray.respond_to?(:per_element)
  end
end
