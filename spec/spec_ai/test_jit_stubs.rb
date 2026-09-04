require "test/unit"
require "carray"

# `jit_for` and `jit_eval` compile their block, and the compiler is the
# carray-jit gem.  CArray names them so that a program written against them
# reads the same wherever it runs, and says plainly where the compiler is
# when it is not there -- rather than running a Ruby loop a hundred times
# slower and leaving the caller to wonder.
class TestJitStubs < Test::Unit::TestCase

  def test_they_are_named_here
    assert_true CArray.respond_to?(:jit_for)
    assert_true CArray.respond_to?(:jit_eval)
  end

  def test_calling_one_without_the_compiler_says_where_it_is
    [[:jit_for, [3]], [:jit_eval, []]].each do |name, arguments|
      error = assert_raise(NotImplementedError) do
        CArray.send(name, *arguments) { |i| i }
      end
      assert_match(/carray-jit/, error.message)
      assert_match(/not installed/, error.message)
    end
  end

  def test_and_points_at_what_needs_no_compiler
    error = assert_raise(NotImplementedError) { CArray.jit_eval { } }
    assert_match(/CArray\.fuse/, error.message)
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
