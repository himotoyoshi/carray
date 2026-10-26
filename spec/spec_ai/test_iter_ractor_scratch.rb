require "test/unit"
require "rbconfig"
require "carray"

# Reductions in several Ractors at once.  The kernel iterator holds the
# object cells of its scratch for the GC; each Ractor keeps its own table,
# so walks running at the same time never share it.  The lazy arena, which also
# lends scratch to eager code (the mask of a view), is per Ractor too.

class TestIterRactorScratch < Test::Unit::TestCase

  # `view` is evaluated afresh on every iteration, as a user would write it.
  def script (n_ractors, iters, setup, view)
    <<~RUBY
      require "carray"
      Warning[:experimental] = false
      rs = #{n_ractors}.times.map do |id|
        Ractor.new(id) do |id|
          #{setup}
          ref = (#{view}).copy.sum(axis: 0).to_a
          bad = 0
          #{iters}.times do
            bad += 1 unless (#{view}).sum(axis: 0).to_a == ref
          end
          bad
        end
      end
      vals = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
      exit(vals.all?(0) ? 0 : 3)
    RUBY
  end

  # Runs the script in a child; a child still running after `limit`
  # seconds is killed and reported.
  def run_child (src, limit)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    pid = Process.spawn(RbConfig.ruby, *inc, "-e", src,
                        out: File::NULL, err: File::NULL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    loop do
      done, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if done
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill(:KILL, pid)
        Process.wait(pid)
        return :timeout
      end
      sleep 0.05
    end
  end

  def assert_child_ok (src, limit = 60)
    omit "Ractor not available" unless defined?(Ractor)
    st = run_child(src, limit)
    assert_not_equal :timeout, st, "child did not finish in #{limit} s"
    assert_equal 0, st.exitstatus, "child ended with #{st.inspect}"
  end

  def test_large_scratch_in_parallel_ractors
    assert_child_ok script(16, 3000,
                           "a = CArray.new(CA_FLOAT64, [600, 600]); a.seq!",
                           "a.shift(1, 0)")
  end

  def test_object_scratch_in_parallel_ractors
    assert_child_ok script(8, 2000,
                           "o = CArray.object(40, 40) { |i, j| i + j }",
                           "o.shift(1, 0, fill_value: 0)")
  end

  # Reading a view's mask takes scratch from the lazy arena.  Rows of
  # different widths make the Ractors ask for different sizes.
  def test_mask_scratch_in_parallel_ractors
    src = <<~RUBY
      require "carray"
      Warning[:experimental] = false
      rs = 8.times.map do |id|
        Ractor.new(id) do |id|
          cols = 16 + id * 40
          n = 8192
          m = CArray.float64(n, cols).seq!
          b = CArray.boolean(n, cols)
          b[n - 1, cols - 1] = 1 if id.even?
          m.mask = b
          odd, even = m[[1, n / 2, 2], nil], m[[0, n / 2, 2], nil]
          bad = 0
          3000.times do
            bad += 1 unless odd.any_masked? == id.even?
            bad += 1 unless even.all_masked? == false
          end
          bad
        end
      end
      vals = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
      exit(vals.all?(0) ? 0 : 3)
    RUBY
    assert_child_ok src
  end
end
