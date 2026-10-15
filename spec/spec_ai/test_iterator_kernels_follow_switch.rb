# The categorical, segment and group iterators answer most reductions by C
# kernels of their own (the reduceat, fiber scatter and scan kernels, the
# group engine), a faster way to what the core answers for each group.  A
# development build run with CARRAY_GENERAL_PATH set switches them off, and
# then every group is reduced by the core itself.  This runs one battery of
# reductions both ways, in two child processes, and checks that
#
#   - with the fast paths off no kernel runs (but the engine for a band
#     folded into the statistic, which has no other route), and with them
#     on the kernels do -- so the spy sees them;
#   - both ways give the same values in the same data types.
#
# The kernels spied on are the per-group ones utils/dunder_methods.txt
# lists, so a kernel added there is covered without editing this file.

require "test/unit"
require "rbconfig"
require "tmpdir"
require "carray"

class TestIteratorKernelsFollowSwitch < Test::Unit::TestCase

  ROOT = File.expand_path("../..", __dir__)

  CHILD = <<~'RUBY'
    require "carray"
    require "carray/categorical_iterator"
    require "carray/axis_group"

    calls = Hash.new(0)
    kernels = File.readlines(File.join(ARGV[1], "utils/dunder_methods.txt"))
                  .grep(/\ACArray#__(reduceat|fiber_scatter|scan_by_axis_groups)/)
                  .map { |l| l.split("#")[1].strip.to_sym }
    CArray.prepend(Module.new {
      kernels.each { |k| define_method(k) { |*a, **kw, &b| calls[k] += 1; super(*a, **kw, &b) } }
    })
    %i[sum accumulate prod mean min max variance stddev variancep stddevp
       count count_not_masked all any].each do |op|
      m = CAGroupIterator.instance_method(op)
      m = m.super_method while m && m.owner != CAGroupIterator
      CAGroupIterator.send(:define_method, op) do |*a, **kw, &b|
        calls[kw[:axis].is_a?(Array) ? :engine_fused : :engine] += 1
        m.bind_call(self, *a, **kw, &b)
      end
    end

    n = 12
    vals = [3, -1, 0, 5, 2, 7, 1, 4, 6, -2, 8, 3]
    payloads = {
      int32:   CArray.int32(n) { vals },
      nan:     CArray.float64(n) { vals.map { |v| v * 0.5 } }.tap { |a| a[3] = Float::NAN },
      boolean: CArray.boolean(n) { vals.map { |v| v > 2 ? 1 : 0 } },
      object:  CArray.object(n) { vals.map { |v| Rational(v, 3) } },
      string:  CArray.const_string(vals.map { |v| "s#{v}" }),
    }
    masks = {
      none: ->(a) { a },
      some: ->(a) { a.mask_where(CArray.boolean(n) { |i| [1, 6].include?(i) }) },
      all:  ->(a) { a.mask_where(CArray.boolean(n) { true }) },
    }
    ops = [[:sum], [:accumulate], [:prod], [:mean], [:min], [:max], [:minmax],
           [:variance], [:stddev], [:variancep], [:stddevp], [:all], [:any],
           [:median], [:percentile, 30], [:quantile], [:first], [:last],
           [:nunique], [:count], [:count_not_masked], [:count_masked],
           [:min_index], [:sum, { min_count: 2 }]]
    scans = %i[cumsum cumprod cummax cummin cumcount]

    norm = lambda do |x|
      case x
      when CArray    then [x.data_type, x.shape, x.to_a.flatten.map { |v| norm.(v) }]
      when Array     then x.map { |e| norm.(e) }
      when Exception then [:raised, x.class.name]
      when Float     then x.nan? ? :nan : (x.finite? ? x.round(9) : x)
      when true      then 1
      when false     then 0
      else x == UNDEF ? :undef : x
      end
    end
    ask = lambda do |&b|
      norm.(b.call)
    rescue StandardError, NotImplementedError => e
      norm.(e)
    end

    out = {}
    payloads.each do |pn, payload|
      masks.each do |mn, mask|
        src = mask.(payload)
        w   = CArray.float64(n) { |i| [0.5, 2.0, 0.0][i % 3] }
        h   = src.reshape(3, 4)
        flat = {
          cat: -> { src.group_by_category(CA_INT32([0, 1, 2, 0, 1, 2, 0, 1, 3, 0, 1, 2]).categorize) },
          seg: -> { src.segments(offsets: CA_INT64([0, 4, 4, 9])) },
        }
        flat.each do |iname, it|
          ops.each { |op, *a| kw = a.last.is_a?(Hash) ? a.pop : {}; out[[pn, mn, iname, op, a, kw]] = ask.() { it.().public_send(op, *a, **kw) } }
          scans.each { |op| out[[pn, mn, iname, op]] = ask.() { it.().public_send(op) } }
          out[[pn, mn, iname, :wsum]]  = ask.() { it.().wsum(w) }
          out[[pn, mn, iname, :wmean]] = ask.() { it.().wmean(w) }
        end
        groups = {
          grp:  -> { h[CA_INT32([0, 1, 0]).categorize, nil] },
          grp2: -> { h[CA_INT32([0, 1, 0]).categorize, CA_INT32([0, 0, 1, 1]).categorize] },
        }
        groups.each do |iname, it|
          ops.each { |op, *a| kw = a.last.is_a?(Hash) ? a.pop : {}; out[[pn, mn, iname, op, a, kw]] = ask.() { it.().public_send(op, *a, axis: :group, **kw) } }
          scans.each { |op| out[[pn, mn, iname, op]] = ask.() { it.().public_send(op, axis: :group) } }
          out[[pn, mn, iname, :wmean]] = ask.() { it.().wmean(w.reshape(3, 4), axis: :group) }
        end
        out[[pn, mn, :fused]] = ask.() { groups[:grp].().sum(axis: [:group, 1]) }
        { caseA: [0, 1, 0, 2], caseB: [0, 1, 2, 0, 1, 2, 0, 1, 3, 0, 1, 2], band: [0, 1, 1] }.each do |cn, codes|
          cat = CA_INT32(codes).categorize
          cat = CA_INT32(codes).reshape(3, 4).categorize if cn == :caseB
          ops.each { |op, *a| kw = a.last.is_a?(Hash) ? a.pop : {}; out[[pn, mn, cn, op, a, kw]] = ask.() { h.group_by_category(cat).public_send(op, *a, axis: 1, **kw) } }
          out[[pn, mn, cn, :wsum]] = ask.() { h.group_by_category(cat).wsum(w.reshape(3, 4), axis: 1) }
          out[[pn, mn, cn, :cumsum]] = ask.() { h.group_by_category(cat).cumsum(axis: 1) } if cn == :caseA
        end
      end
    end
    File.binwrite(ARGV[0], Marshal.dump([CArray.__fast_paths_enabled__, calls, out]))
  RUBY

  def run_child (general)
    path = File.join(Dir.tmpdir, "kernels_switch_#{Process.pid}_#{general ? 'off' : 'on'}.bin")
    env  = { "CARRAY_GENERAL_PATH" => general ? "1" : nil }
    inc  = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    ok   = system(env, RbConfig.ruby, *inc, "-e", CHILD, path, ROOT)
    assert ok, "child (fast paths #{general ? 'off' : 'on'}) failed"
    Marshal.load(File.binread(path))
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_kernels_follow_the_switch
    off_enabled, off_calls, off = run_child(true)
    omit "a development build is needed to switch the fast paths off" if off_enabled
    _, on_calls, on = run_child(false)

    assert_equal({}, off_calls.reject { |k, _| k == :engine_fused },
                 "a kernel ran with the fast paths off")
    assert_operator off_calls[:engine_fused], :>, 0
    (on_calls.keys - [:engine_fused]).each { |k| assert_operator on_calls[k], :>, 0 }
    assert_operator on_calls.size, :>=, 10, "the spy saw too few kernels: #{on_calls.keys}"

    differ = on.keys.reject { |k| on[k] == off[k] }
    assert_equal([], differ.first(5).map { |k| [k, on[k], off[k]] },
                 "#{differ.size} answers differ between the fast and the general path")
  end
end
