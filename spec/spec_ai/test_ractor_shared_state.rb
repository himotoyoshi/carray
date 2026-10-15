require "test/unit"
require "rbconfig"
require "carray"

# State that every Ractor reaches: what C keeps for the life of the process
# is either per Ractor, behind a lock, or immutable.  Each script runs eight
# Ractors whose right answers differ, and exits non-zero on a wrong one.

class TestRactorSharedState < Test::Unit::TestCase

  def run_child (src, env = {}, limit = 90)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    pid = Process.spawn(env, RbConfig.ruby, *inc, "-e", src,
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

  def assert_ractors_agree (body, env = {})
    omit "Ractor not available" unless defined?(Ractor)
    src = <<~RUBY
      require "carray"
      Warning[:experimental] = false
      rs = 8.times.map { |id| Ractor.new(id) { |id| #{body} } }
      vals = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
      exit(vals.all?(0) ? 0 : 3)
    RUBY
    st = run_child(src, env)
    assert_not_equal :timeout, st, "child did not finish"
    assert_equal 0, st.exitstatus, "child ended with #{st.inspect}"
  end

  # The sort's comparator gets its strings through its own argument.
  def test_const_string_sort_index
    assert_ractors_agree <<~'BODY'
      words = (0...(50 + id * 37)).map { |i| "w#{(i * 7919 + id) % 1000}x#{id}" }
      cs = CArray.const_string(words)
      want = words.each_with_index.sort_by { |w, i| [w, i] }.map(&:last)
      (0...1000).count { cs.sort_index.to_a != want }
    BODY
  end

  # The "Ns" formats are kept in one table, filled by whichever Ractor asks.
  def test_fixlen_memory_view_formats
    assert_ractors_agree <<~'BODY'
      arrays = (1..512).map { |b| CArray.fixlen(4, bytes: b + id * 512) }
      (0...3000).count do |k|
        a = arrays[k % 512]
        CArray.wrap_memory_view(a).bytes != a.bytes
      end
    BODY
  end

  # The method an error names belongs to the Ruby thread that raised it,
  # also when Ractors share native threads.
  def test_an_error_names_its_own_method
    assert_ractors_agree(<<~'BODY', { "RUBY_MN_THREADS" => "1" })
      a = CArray.float64(3).seq
      (0...300).count do
        msg = CArray.send(:__name_errors_after_method__, :"meth#{id}") do
          sleep 0.0002
          begin; a.sum(axis: 7); ""; rescue => e; e.message; end
        end
        ! msg.start_with?("meth#{id}:")
      end
    BODY
  end

  # CATime's methods do not require a library while they run: Ractors
  # requiring at the same time deadlock.
  def test_time_methods_in_parallel_ractors
    assert_ractors_agree <<~'BODY'
      t = CArray.int64(100) { |i| i }.time(unit: :D)
      (0...300).count { t[0].to_s != "1970-01-01" }
    BODY
  end

  def test_undef_is_shareable
    assert_true UNDEF.frozen?
    assert_true Ractor.shareable?(UNDEF) if defined?(Ractor)
    assert_ractors_agree <<~'BODY'
      c = CArray.int32(3).seq!
      c[1] = UNDEF
      c[1].equal?(UNDEF) ? 0 : 1
    BODY
  end
end
