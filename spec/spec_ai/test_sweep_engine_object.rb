# spec_ai/test_sweep_engine_object.rb
#
# A sweep callback may call Ruby, so a collection can run in the middle of
# the walk.  An object input that is not a plain array is read into a
# scratch; the values there may exist nowhere else and have to survive.
# Pinned through both paths of the raw bridge.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_sweep_raw", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "sweep_raw"
rescue LoadError
  warn "[skip] test_sweep_engine_object.rb: sweep_raw fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepEngineObject < Test::Unit::TestCase

  RAW = [:__sweep_raw_to_s__, :__sweep_raw_to_s_slab__]
  N   = 50

  class Computed < CAObject
    def initialize (n)
      super(CA_OBJECT, [n])
    end

    def fetch_addr (i)
      "v#{i}" * 3
    end

    def copy_data (data)
      data[] = CA_OBJECT((0...elements).map { |i| "v#{i}" * 3 })
    end
  end

  def floats
    CArray.float64(N) { |i| 1e300 * (i + 1) / 1e3 }
  end

  def sources
    {
      lazy:     CA_OBJECT((0...N).map { |i| "s#{i}" }).lazy + "y",
      as_type:  floats.as_type(:object),
      wrapped:  CArray.wrap_readonly(floats, CA_OBJECT),
      computed: Computed.new(N),
    }
  end

  def test_scratch_input_survives_a_collection_in_the_callback
    RAW.each do |m|
      sources.each do |name, source|
        out = CArray.object(N)
        CArray.send(m, out, source)
        assert_equal source.copy.to_a.map(&:to_s), out.to_a, "#{m} #{name}"
      end
    end
  end

  def test_masked_scratch_input
    RAW.each do |m|
      source = floats.as_type(:object)
      source[[3, 7]] = UNDEF
      out = CArray.object(N)
      CArray.send(m, out, source)
      assert_equal source.is_masked.to_a, out.is_masked.to_a, m.to_s
      expect = source.to_a.map { |v| v == UNDEF ? UNDEF : v.to_s }
      assert_equal expect, out.to_a, m.to_s
    end
  end

  # The scratch is released on the way out of a raising read, or a later
  # collection would mark a freed buffer.
  def test_raising_read_releases_the_scratch
    bad = Class.new(Computed) {
      def fetch_addr (i) = raise("no")
      def copy_data (data) = raise("no")
    }
    RAW.each do |m|
      assert_raise(RuntimeError, m.to_s) { CArray.send(m, CArray.object(N), bad.new(N)) }
    end
    assert_nothing_raised { GC.start }
  end
end
