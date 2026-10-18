# median / percentile / quantile along an axis take a partition (one p) or a
# shared sort (several p) when nothing asks for a per-fiber count -- no mask,
# min_count:, fill_value:.  Those are faster ways to what the per-fiber select
# answers, and a development build run with CARRAY_GENERAL_PATH set takes the
# per-fiber select every time.  This runs one battery both ways, in two child
# processes, and compares the answers.

require "test/unit"
require "rbconfig"
require "tmpdir"
require "carray"

class TestOrderStatisticsFollowSwitch < Test::Unit::TestCase

  CHILD = <<~'RUBY'
    require "carray"
    srand(7)
    norm = lambda do |x|
      case x
      when CArray    then [x.class.name, x.data_type, x.shape, x.to_a.flatten.map { |v| norm.(v) }]
      when Array     then x.map { |e| norm.(e) }
      when Exception then [:raised, x.class.name]
      when Float     then x.nan? ? :nan : (x.finite? ? x.round(9) : x)
      else x == UNDEF ? :undef : x
      end
    end
    ask = lambda do |&b|
      norm.(b.call)
    rescue StandardError => e
      norm.(e)
    end
    gens = {
      int32:  ->(n) { CArray.int32(n) { |i| rand(-5..5) } },
      f64:    ->(n) { CArray.float64(n) { |i| [rand * 4, Float::NAN, Float::INFINITY, -Float::INFINITY][i % 5 == 0 ? rand(4) : 0] } },
      bool:   ->(n) { CArray.boolean(n) { |i| rand(2) } },
      obj:    ->(n) { CArray.object(n) { |i| Rational(rand(-6..6), 3) } },
      string: ->(n) { CArray.const_string(Array.new(n) { |i| "s#{rand(5)}" }).to_string },
    }
    out = {}
    [[7], [4, 5], [2, 3, 4]].each do |sh|
      n = sh.inject(:*)
      gens.each do |gn, g|
        a = g.(n).reshape(*sh)
        sh.size.times do |ax|
          [false, true].each do |keep|
            out[[sh, gn, ax, keep, :median]]   = ask.() { a.median(axis: ax, keep_axis: keep) }
            out[[sh, gn, ax, keep, :quantile]] = ask.() { a.quantile(axis: ax, keep_axis: keep) }
            [[30], [0, 50, 100]].each do |ps|
              %i[linear lower higher nearest midpoint].each do |m|
                out[[sh, gn, ax, keep, ps, m]] = ask.() { a.percentile(*ps, axis: ax, method: m, keep_axis: keep) }
              end
            end
          end
        end
      end
    end
    File.binwrite(ARGV[0], Marshal.dump([CArray.__fast_paths_enabled__, out]))
  RUBY

  def run_child (general)
    path = File.join(Dir.tmpdir, "order_stat_switch_#{Process.pid}_#{general ? 'off' : 'on'}.bin")
    env  = { "CARRAY_GENERAL_PATH" => general ? "1" : nil }
    inc  = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    assert system(env, RbConfig.ruby, *inc, "-e", CHILD, path),
           "child (fast paths #{general ? 'off' : 'on'}) failed"
    Marshal.load(File.binread(path))
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_shortcuts_answer_as_the_per_fiber_select
    off_enabled, off = run_child(true)
    omit "a development build is needed to switch the fast paths off" if off_enabled
    _, on = run_child(false)
    differ = on.keys.reject { |k| on[k] == off[k] }
    assert_equal([], differ.first(5).map { |k| [k, on[k], off[k]] },
                 "#{differ.size} answers differ between the fast and the general path")
  end


end
