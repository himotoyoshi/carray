require "test/unit"
require "carray"

# Two compilations of the same C need not agree on the last bit: what a
# compiler may fuse or reorder is decided by the flags it was given.  So
# anything computing what these kernels compute, somewhere other than in
# them, has to be built the same way -- and has to be told how.
class TestBuildFlags < Test::Unit::TestCase

  def test_it_says_how_the_arithmetic_was_built
    assert_kind_of String, CArray::BUILD_FLAGS
    assert_not_empty CArray::BUILD_FLAGS
  end

  def test_it_carries_the_optimisation_level_ruby_itself_was_built_with
    RbConfig::CONFIG["optflags"].split.each do |flag|
      assert_include CArray::BUILD_FLAGS, flag
    end
  end

  def test_it_is_flags_and_nothing_else
    CArray::BUILD_FLAGS.split.each do |flag|
      assert_match(/\A-/, flag, "#{flag.inspect} is not a flag")
    end
  end

  def test_it_leaves_out_what_does_not_bear_on_the_arithmetic
    # Warnings, defines and link options change nothing about the numbers,
    # and a consumer compiling one small file should not have to carry them.
    %w[-Wall -DCARRAY_BUILD -DCARRAY_DEV_BUILD -fPIC -shared].each do |flag|
      assert_not_include CArray::BUILD_FLAGS, flag
    end
  end

end
