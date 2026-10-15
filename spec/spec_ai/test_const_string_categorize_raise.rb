# spec_ai/test_const_string_categorize_raise.rb
#
# CAConstString#categorize builds a hash table and two level arrays before
# it reads the offsets, and reading them can raise when the offsets come
# from an array that answers in Ruby.  The tables are Ruby's temporaries
# (ALLOCV), so a raise does not leave them behind.
#
# 32768 cells make the tables 768 KB, so a leak shows far above the 4 KB
# threshold, measured by utils/measure_leak.rb (macOS only).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestConstStringCategorizeRaise < Test::Unit::TestCase

  SETUP = <<~RUBY
    class FailingOffsets < CAObject
      def initialize (n)
        @src = CArray.fixlen(n, bytes: 16)
        @src[] = [0, 1].pack("q<q<")
        super(CA_FIXLEN, [n], bytes: 16)
      end
      private
      def copy_data (data) = $fail ? raise(IOError, "gone") : (data[] = @src)
      def fetch_addr (addr) = $fail ? raise(IOError, "gone") : @src[addr]
      def create_mask; end
    end
    strings = CAConstString.wrap(FailingOffsets.new(32768), buffer: "abcdef")
    $fail = true
  RUBY

  def test_raises
    scope = binding
    eval(SETUP, scope)
    strings = scope.local_variable_get(:strings)
    assert_raise(IOError) { strings.categorize }
  ensure
    $fail = false
  end

  def test_a_raising_read_frees_the_tables
    grown = LeakMeter.bytes_per_call("strings.categorize rescue nil", setup: SETUP)
    omit "malloc zone statistics unavailable" if grown.nil?
    assert_operator grown, :<, 4096,
                    "categorize: the malloc zone grew #{grown.round} bytes per call"
  end
end
