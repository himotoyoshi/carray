# Checks, around every test, that the test left no view attached.
#
# A view's attach level goes up when it is attached (or allocated) and down
# when it is detached.  Code that raises between the two can skip the
# detach, and the view stays attached, with any buffer it materialised.
# Nothing else reports this: the test that did it passes.  A development
# build counts the views whose level is above zero, and this compares the
# count before and after each test.
#
# `rake spec_ai` loads this file ahead of the tests.  A single test file
# run by hand is checked the same way when loaded with it:
#
#   ruby -Iext -Ilib -r ./spec/spec_ai/attach_balance.rb spec/spec_ai/test_foo.rb
#
# In a release build the count does not exist and nothing is checked.

require "test/unit"
require "carray"

if CArray.respond_to?(:__attached_views__)
  class Test::Unit::TestCase
    setup    :record_attached_views, before: :prepend
    teardown :check_attached_views,  after: :append

    private

    def record_attached_views
      @attached_views_before = CArray.__attached_views__
    end

    def check_attached_views
      return unless @attached_views_before
      left = CArray.__attached_views__ - @attached_views_before
      assert_equal 0, left, "this test left #{left} view(s) attached"
    end
  end
end
