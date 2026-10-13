# A view takes its parent's mask by asking the parent whether it has one.
# A CAObject answers in Ruby, and when the answer raises, the view being
# built belongs to no Ruby object yet: its struct and the metadata its
# setup allocated must be freed.  The constructors ask after the setup,
# under ca_fill_or_free (ca_view_inherit_mask).
#
# The struct is small, so the parent has 8 axes and each case runs 3000
# times; measured with utils/measure_leak.rb (macOS only).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestViewParentMaskRaiseCleanup < Test::Unit::TestCase

  SETUP = <<~RUBY
    class AskBoom < CAObject
      def initialize (*dim); super(CA_FLOAT64, dim); end
      def mask_created?; $boom ? raise("boom") : false; end
      private
      def fetch_index (idx); 1.0; end
    end
    b = AskBoom.new(*[2] * 8)
    $boom = true
  RUBY

  VIEWS = [
    "b.tile(*[2] * 8)",
    "b.roll(*[1] * 8)",
    "b.fake(CA_INT64)",
    "b.transpose",
    "b[0..0, nil, nil, nil, nil, nil, nil, nil]",
    "b.reshape(256)",
    "b.shift(*[1] * 8, fill_value: UNDEF)",
    "b.lazy",
  ]

  def test_raises
    eval(SETUP.sub("b = ", "b0 = ").sub("$boom = true", ""))
    b = AskBoom.new(*[2] * 8)
    $boom = true
    VIEWS.each do |expr|
      assert_raise_kind_of(StandardError, expr) { eval(expr) }
    end
  ensure
    $boom = nil
  end

  def test_views_free_what_they_took
    VIEWS.each do |expr|
      bytes = LeakMeter.bytes_per_call(expr, setup: SETUP, calls: 3000, warmup: 100)
      omit "malloc zone statistics unavailable" if bytes.nil?
      assert_operator bytes, :<, 50,
                      "#{expr}: the malloc zone grew #{bytes.round} bytes per call"
    end
  end

end
