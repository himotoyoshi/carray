require "test/unit"
require "carray"
require "rbconfig"
require "open3"

# A development build switches a fast path off by its name, with
# CARRAY_SHORTCUTS_OFF in the environment, and all of them with
# CARRAY_GENERAL_PATH=1.  CArray.__fast_paths_enabled__ answers for one name
# or for all.
class TestShortcutSwitch < Test::Unit::TestCase

  def setup
    omit "development build only" unless CArray.respond_to?(:__attached_views__)
  end

  def answer_in_child (env, names)
    lib = File.expand_path("../../lib", __dir__)
    ext = File.expand_path("../../ext", __dir__)
    code = "require 'carray'; p #{names.inspect}.map { |n| CArray.__fast_paths_enabled__(n) }"
    env = { "CARRAY_GENERAL_PATH" => nil, "CARRAY_SHORTCUTS_OFF" => nil }.merge(env)
    out, err, = Open3.capture3(env, RbConfig.ruby, "-I#{ext}", "-I#{lib}", "-e", code)
    [eval(out), err]
  end

  def test_every_name_answers_on_by_default
    names = %i[stack stack_outer_k meld_reduce window_fold_by_offset]
    got, err = answer_in_child({}, names)
    assert_equal [true] * names.size, got
    assert_equal "", err
  end

  def test_an_unknown_name_is_refused
    assert_raise(ArgumentError) { CArray.__fast_paths_enabled__(:no_such_shortcut) }
  end

  def test_the_named_ones_are_off_and_the_rest_on
    got, err = answer_in_child({ "CARRAY_SHORTCUTS_OFF" => "stack,meld_reduce" },
                               %i[stack meld_reduce stack_outer_k])
    assert_equal [false, false, true], got
    assert_equal "", err
  end

  def test_an_unknown_name_in_the_environment_is_warned_about
    got, err = answer_in_child({ "CARRAY_SHORTCUTS_OFF" => "stak" }, %i[stack])
    assert_equal [true], got
    assert_match(/unknown shortcut stak/, err)
  end

  def test_the_general_path_turns_every_name_off
    got, = answer_in_child({ "CARRAY_GENERAL_PATH" => "1" }, %i[stack stack_outer_k])
    assert_equal [false, false], got
  end

end
