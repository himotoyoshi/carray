require "test/unit"
require "rbconfig"
require "carray"

# Reductions in several Ractors at once.  The kernel iterator keeps one
# large scratch buffer for the next walk; each Ractor keeps its own, so
# walks running at the same time never hand the same buffer to two owners.

class TestIterRactorScratch < Test::Unit::TestCase

  SCRIPT = <<~'RUBY'
    require "carray"
    Warning[:experimental] = false
    rs = 16.times.map do |id|
      Ractor.new(id) do |id|
        a = CArray.new(CA_FLOAT64, [600, 600]); a.seq!
        ref = a.shift(1, 0).copy.sum(axis: 0).to_a
        bad = 0
        3000.times do
          bad += 1 unless a.shift(1, 0).sum(axis: 0).to_a == ref
        end
        bad
      end
    end
    vals = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
    exit(vals.all?(0) ? 0 : 3)
  RUBY

  def test_large_scratch_in_parallel_ractors
    omit "Ractor not available" unless defined?(Ractor)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    system(RbConfig.ruby, *inc, "-e", SCRIPT, out: File::NULL, err: File::NULL)
    assert_equal 0, $?.exitstatus, "child ended with #{$?.inspect}"
  end

end
