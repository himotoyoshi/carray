# frozen_string_literal: true
#
# An error names the method the user called.  Going out from where it is
# raised, that is the last frame of the library -- a Ruby method under lib/,
# or a C method of a CA* class or a CA_* conversion -- before the user's own
# code is reached.  A core C method on the way (Array#map, Class#new) is
# passed through, and the user's block ends the walk.
#
# A family of iterator reductions made by define_method had no name in its
# frames and named what it called: segments(...).all and a key window's all
# said per_segment.  They are made by CArray.define_named_methods now, one
# `def` per name.
#
# Before, the name was the innermost C method's.  A Ruby method of the
# library over a C one named the C one: value_counts said sort_index,
# CA_INT32 and to_ca said guess_array_shape, CArray.int32 and CArray.new said
# initialize; and on its first call through the autoload stub a method was
# named autoload_define.  Only the methods wrapped by hand in
# CArray.__name_errors_after_method__ said their own names.

require "test/unit"
require "carray"

class TestErrorNamesCalledMethod < Test::Unit::TestCase

  def name_of
    yield
    flunk "no error"
  rescue StandardError => e
    e.message[/\A[\w.!?#\[\]=<>+\-*\/%]+(?=: )/]
  end

  def deep_array (levels)
    v = 1
    levels.times { v = [v] }
    v
  end

  def test_a_ruby_method_over_a_c_one_is_named
    assert_equal "value_counts", name_of { CA_OBJECT([1, "a"]).value_counts(sort: :value) }
    assert_equal "nlargest",     name_of { CA_OBJECT([1, "a"]).nlargest(1) }
    assert_equal "join",         name_of { CA_INT32([1]).join(",", axis: 1.5) }
  end

  def test_a_conversion_is_named
    deep = deep_array(CA_RANK_MAX + 1)
    assert_equal "CA_INT32", name_of { CA_INT32(deep) }
    assert_equal "to_ca",    name_of { deep.to_ca }
  end

  def test_a_constructor_is_named
    assert_equal "int32", name_of { CArray.int32(*[1] * (CA_RANK_MAX + 1)) }
    assert_equal "new",   name_of { CArray.new(:int32, [1] * (CA_RANK_MAX + 1)) }
  end

  def test_a_c_method_calling_another_is_named
    assert_equal "median",         name_of { CA_INT32([1]).median(axis: 3) }
    assert_equal "partition_copy", name_of { CA_INT32([1]).partition_copy(0, axis: 3) }
  end

  # The user's block ends the walk: the error inside it is the inner call's.
  def test_the_users_block_ends_the_walk
    assert_equal "sum", name_of { [CA_INT32([1])].map { |a| a.sum(axis: 5) } }
    assert_equal "sum", name_of { CA_INT32([1, 2]).each_slab(axis: 0) { |s| s.sum(axis: 7) } }
  end

  # The same in a fresh process, where the first call of an autoloaded
  # method goes through its stub.
  def test_the_first_call_through_an_autoload_stub
    script = 'require "carray"; begin; CA_OBJECT([1, "a"]).value_counts(sort: :value); ' \
             'rescue ArgumentError => e; puts e.message[/\A\w+/]; end'
    out = IO.popen([RbConfig.ruby, *$LOAD_PATH.grep(/carray/).flat_map { |p| ["-I", p] },
                    "-e", script], err: File::NULL, &:read)
    assert_equal "value_counts", out.chomp
  end

  # Methods of an iterator family, each a def made by define_named_methods.
  def test_an_iterator_family_is_named
    o = CA_OBJECT([1, "a", 2, "b"])
    t = CA_DOUBLE([0, 1, 2, 3])
    assert_equal "all", name_of { o.segments(lengths: [2, 2]).all }
    assert_equal "all", name_of { o.windows(on: t, before: 1).all }
    assert_equal "min", name_of { o.segments(lengths: [2, 2]).min }
    assert_equal "min", name_of { o.blocks(2).min }
    # a scan of tiles takes no arguments, as before
    e = assert_raise(ArgumentError) { CA_DOUBLE([1, 2, 3, 4]).blocks(2).cumsum(1) }
    assert_equal "wrong number of arguments (given 1, expected 0)", e.message
  end

  # An explicit name still wins over the walk.
  def test_an_explicit_name_wins
    assert_equal "outer", name_of {
      CArray.__name_errors_after_method__(:outer) { CA_INT32([1]).sum(axis: 5) }
    }
  end

end
