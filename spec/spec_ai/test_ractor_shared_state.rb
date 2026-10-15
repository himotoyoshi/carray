require "test/unit"
require "rbconfig"
require "tempfile"
require "carray"

# State that every Ractor reaches: what C keeps for the life of the process
# is either per Ractor, behind a lock, or immutable.  Each script runs eight
# Ractors whose right answers differ, and exits non-zero on a wrong one.

class TestRactorSharedState < Test::Unit::TestCase

  # The script is a file, so that fuse can read a block's source.
  def run_child (src, env = {}, limit = 90)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    script = Tempfile.new(["ractor_child", ".rb"])
    script.write(src)
    script.close
    pid = Process.spawn(env, RbConfig.ruby, *inc, script.path,
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
      require "carray/struct"    # loaded on first use, which only the main Ractor can do
      CArray.expression_evaluator = ->(plan, out) { false } if ENV["CARRAY_TEST_EVALUATOR"]
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

  # What the main Ractor computes, a Ractor computes: operators, the lazy
  # builders, comparisons, reductions, a frame, a struct and fuse.
  def test_the_surface_answers_in_a_ractor
    assert_ractors_agree <<~'BODY'
      a = CArray.float64(30).seq!
      b = CArray.float64(30) { 2.0 }
      want = (0...30).map { |i| i * 2.0 + 1 }
      bad = 0
      bad += 1 unless (a * b + 1).to_a == want
      bad += 1 unless (a.lazy * b + 1).copy.to_a == want
      bad += 1 unless CArray.fuse { a * b + 1 }.copy.to_a == want
      bad += 1 unless a.add(1).pow(2)[2] == 9.0 && (a > 28.0).count(true) == 1
      bad += 1 unless (-a).sum == -435.0 && a.mean == 14.5
      df = CAFrame.new({ "x" => CA_INT32([1, 2, 3]), "y" => CA_DOUBLE([4, 5, 6]) })
      bad += 1 unless df["y"].sum == 15.0
      st = CArray.struct { int32 :i ; float64 :f }
      rec = CARecord.new(st, 2)
      rec["i"][] = 7
      bad += 1 unless rec["i"].to_a == [7, 7] && st.new(i: 1, f: 2.5).f == 2.5
      bad
    BODY
  end

  # A frozen array is shared, not copied: each Ractor makes its own views
  # of the same object.
  def test_a_frozen_array_is_shared
    omit "Ractor not available" unless defined?(Ractor)
    src = <<~'RUBY'
      require "carray"
      Warning[:experimental] = false
      a = CArray.float64(200, 100) { |i, j| i * 100.0 + j }
      a[3, 4] = UNDEF
      Ractor.make_shareable(a.freeze)
      want = [a.sum, a[10..150, 5..90].sum, a.transpose[3..50, nil].mean, a.object_id]
      rs = 8.times.map do
        Ractor.new(a, Ractor.make_shareable(want)) do |x, w|
          (0...50).count { [x.sum, x[10..150, 5..90].sum, x.transpose[3..50, nil].mean, x.object_id] != w }
        end
      end
      vals = rs.map { |r| r.respond_to?(:value) ? r.value : r.take }
      exit(vals.all?(0) ? 0 : 3)
    RUBY
    st = run_child(src)
    assert_equal 0, st.exitstatus, "child ended with #{st.inspect}"
    assert_false Ractor.shareable?(CArray.float64(3).seq![0..1])
  end

  # An evaluator registered in the main Ractor is asked there only.
  def test_a_ractor_walks_without_the_evaluator
    assert_ractors_agree(<<~'BODY', { "CARRAY_TEST_EVALUATOR" => "1" })
      a = CArray.float64(20_000).seq!
      c = CArray.float64(20_000)
      c[] = a.lazy + 1
      (c[5] == 6.0 && CArray.expression_evaluator.nil?) ? 0 : 1
    BODY
  end

  # A method its library has not been loaded for says where to load it.
  def test_an_autoload_stub_names_its_library
    omit "Ractor not available" unless defined?(Ractor)
    src = <<~'RUBY'
      require "carray"
      Warning[:experimental] = false
      r = Ractor.new { begin; CArray.float64(3).seq!.histogram1d(3); rescue => e; e.message; end }
      msg = r.respond_to?(:value) ? r.value : r.take
      exit(msg.include?("carray/histogram") && msg.include?("main Ractor") ? 0 : 3)
    RUBY
    st = run_child(src)
    assert_equal 0, st.exitstatus, "child ended with #{st.inspect}"
  end
end
