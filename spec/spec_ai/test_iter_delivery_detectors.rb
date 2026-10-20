# What a kernel iterator walk must not leave behind.  The delivery matrix
# (test_iter_delivery_matrix.rb) checks the values a kernel receives and
# writes; these promises do not show in the values, so each has its own
# detector, run over the same cases:
#
#   - a walk closes what it opened on every exit: a normal end and a raise
#     in the kernel's body (the views attached, the iterator's buffers, and
#     the memory taken)
#   - a read walk creates nothing on the source or its parents (no mask
#     appears, no value changes)
#   - Ruby values a walk gathers from a source that makes them (a lazy
#     expression over objects, a CAObject) stay alive until the walk ends
#   - a view over part of a lazily backed root asks the root for that part,
#     never for the whole of it
#
# rake spec_ai, spec_ai_general and spec_ai_transfer run these with
# CARRAY_GENERAL_PATH unset, 1 and 2.

require "test/unit"
require "carray"
require_relative "iter_delivery_cases"
require_relative "../../utils/measure_leak"

ext_dir = File.expand_path("ext_iter_write", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_write"
rescue LoadError
  warn "Skipping test_iter_delivery_detectors: iter_write not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterDeliveryDetectors < Test::Unit::TestCase

  include IterDeliveryCases

  CASES = Object.new.extend(IterDeliveryCases)

  # What a development build counts as open: views attached, and buffers
  # the iterator took and has not given back.
  def open_things
    return nil unless CArray.respond_to?(:__attached_views__)
    { views: CArray.__attached_views__, buffers: CArray.__iter_buffers__ }
  end

  # --- every exit closes what the walk opened --------------------------

  def test_a_walk_leaves_nothing_open_on_any_exit
    omit "needs a development build" unless open_things
    cases = 0
    [false, true].each do |masked|
      each_case(READ_VIEWS, masked) do |pn, vn, r, v|
        walks(v).each do |mode, ax, name|
          (VIEWS.key?(vn) ? [false, true] : [false]).each do |write|
            label = "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax} #{write ? "write" : "read"}"
            before = open_things
            write ? CArray.iw_write_cells(v, mode, ax) : CArray.iw_read_cells(v, mode, ax)
            assert_equal before, open_things, "#{label}, normal end"
            assert_raise(RuntimeError, label) { CArray.iw_raise_cells(v, mode, ax, write) }
            assert_equal before, open_things, "#{label}, raise in the body"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

  # Each parent's cases, every walk, a normal end and a raise, repeated so
  # that a scratch left behind in any one of them shows above the noise.
  def test_a_walk_gives_back_the_memory_it_took
    lib = File.expand_path("../../lib", __dir__)
    ext = File.expand_path("../../ext", __dir__)
    setup = <<~RUBY
      require_relative #{File.expand_path("iter_delivery_cases", __dir__).dump}
      $LOAD_PATH.unshift #{File.expand_path("ext_iter_write", __dir__).dump}
      require "iter_write"
      CASES = Object.new.extend(IterDeliveryCases)
    RUBY
    PARENTS.each_key do |pn|
      sweep = <<~RUBY.gsub("\n", "; ")
        n = 0
        [false, true].each { |masked|
          CASES.each_case(IterDeliveryCases::VIEWS, masked) { |pn, vn, r, v|
            next unless pn == #{pn.dump}
            CASES.walks(v).each { |mode, ax, _|
              3.times {
                CArray.iw_read_cells(v, mode, ax)
                CArray.iw_write_cells(v, mode, ax)
                (CArray.iw_raise_cells(v, mode, ax, true) rescue nil)
                n += 1
              }
            }
          }
        }
        n
      RUBY
      # The meter rescues whatever the expression raises, so a sweep that
      # failed would measure nothing; run it here first.
      assert_operator eval(sweep), :>, 0, "#{pn}: the sweep walked nothing"
      # A sweep is 738 rounds of three walks, so 16384 bytes is about 22 bytes
      # a round: a scratch left behind by any walk is far above it.  The heap
      # is still growing for the first sweeps, though; with 3 warm-up sweeps
      # and 8 measured, a sweep that leaks nothing read up to 24 KB.  With
      # 10 and 40 it reads at most 8 KB, and 64 bytes leaked a round read 48 KB.
      bytes = LeakMeter.bytes_per_call(sweep, setup: setup, calls: 40, warmup: 10,
                                       load_path: [ext, lib] + $LOAD_PATH)
      omit "measurement unavailable" if bytes.nil?
      assert_operator bytes, :<, 16384, "#{pn}: the C heap grew #{bytes.round} bytes per sweep"
    end
  end

  # --- a read walk creates nothing -------------------------------------

  # The source and every array it reads through.
  def lineage (v)
    seen = []
    todo = [v]
    until todo.empty?
      a = todo.shift
      next if seen.any? { |x| x.equal?(a) }
      seen << a
      todo << a.parent if a.respond_to?(:parent) && a.parent.is_a?(CArray)
      todo.concat(a.parents) if a.respond_to?(:parents)
    end
    seen
  end

  def test_a_read_walk_creates_nothing_on_the_source_or_its_parents
    cases = 0
    each_case(READ_VIEWS, false) do |pn, vn, r, v|
      walks(v).each do |mode, ax, name|
        chain  = lineage(v)
        masks  = chain.map(&:has_mask?)
        values = r.to_a
        CArray.iw_read_cells(v, mode, ax)
        label = "#{vn} of #{pn}: #{name} axis #{ax}"
        assert_equal masks, chain.map(&:has_mask?), "#{label}: a mask appeared"
        assert_equal values, r.to_a, "#{label}: a value changed"
        cases += 1
      end
    end
    assert_operator cases, :>=, 500
  end

  # --- Ruby values made while gathering stay alive ----------------------

  # A CAObject that makes a fresh Rational for every cell it is asked for.
  class Maker < CAObject
    def initialize (shape)
      super(CA_OBJECT, shape, read_only: true)
    end

    private

    def fetch_addr (addr)
      Rational(addr * 3 + 1, 7)
    end

    def copy_data (data)
      data[] = CArray.object(*shape) { |i| Rational(i * 3 + 1, 7) }
    end
  end

  OBJECT_SOURCES = {
    "lazy over objects" => -> { (CArray.object(3, 4, 5) { |i| Rational(i, 3) }.lazy + 1) },
    "CAObject"          => -> { Maker.new([3, 4, 5]) },
  }

  OBJECT_VIEWS = {
    "itself"      => ->(p) { p },
    "row block"   => ->(p) { p[1..2, nil, nil] },
    "transpose"   => ->(p) { p.transpose },
    "grid"        => ->(p) { p[CA_INT64([2, 0]), nil, CA_INT64([1, 3, 4])] },
    "select axis" => ->(p) { p[CA_BOOLEAN([1, 0, 1]), nil, nil] },
    "roll"        => ->(p) { p.roll(1, 1, 0) },
  }

  def under_gc_stress
    was = GC.stress
    GC.stress = true
    yield
  ensure
    GC.stress = was
  end

  def test_object_values_a_walk_gathers_survive_a_collection
    cases = 0
    OBJECT_SOURCES.each do |sn, make|
      OBJECT_VIEWS.each do |vn, view|
        v = view.call(make.call)
        cells = v.copy.to_a.flatten
        walks(v).each do |mode, ax, name|
          exp = slab_addresses(v.shape, mode, ax).map { |s| s.map { |a| cells[a] } }
          got = under_gc_stress { CArray.iw_read_cells(v, mode, ax) }
          got = [got.flatten(1)] if mode == 0
          assert_equal exp, got, "#{vn} of #{sn}: #{name} axis #{ax}"
          cases += 1
        end
      end
    end
    assert_operator cases, :>=, 50
  end

  # --- a partial view asks the root for its part ------------------------

  # A lazily backed float64 root that records every bulk request.
  class Recorder < CAObject
    attr_reader :log

    def initialize (back)
      @back = back
      @log  = []
      super(CA_FLOAT64, back.shape, read_only: true)
    end

    private

    def fetch_addr (addr)
      @log << [:cell, 1]
      @back[addr]
    end

    def copy_data (data)
      @log << [:copy_data, @back.elements]
      data[] = @back
    end

    def copy_block (starts, counts, steps, data)
      @log << [:copy_block, counts.to_a.inject(:*)]
      data[] = @back[*starts.each_index.map { |k| [starts[k], counts[k], steps[k]] }]
    end

    def copy_addrs (addrs, data)
      @log << [:copy_addrs, addrs.elements]
      data[] = @back[addrs]
    end
  end

  def test_a_partial_view_never_asks_for_the_whole_root
    cases = 0
    PARENTS.each do |pn, (shape, type, parent)|
      next unless type == :float64
      READ_VIEWS.each do |vn, view|
        next if vn == "lazy"
        index = CArray.int64(*shape).seq!
        covered = begin
          view.call(parent.call(index)).copy.to_a.flatten.uniq.size
        rescue ArgumentError, IndexError, TypeError, RangeError
          next
        end
        next if covered == index.elements
        rec = Recorder.new(root(shape, :float64, false))
        v = view.call(parent.call(rec))
        walks(v).each do |mode, ax, name|
          rec.log.clear
          CArray.iw_read_cells(v, mode, ax)
          whole = rec.log.select { |kind, _| kind == :copy_data }
          assert_equal [], whole,
                       "#{vn} of #{pn}: #{name} axis #{ax} covers #{covered} of " \
                       "#{index.elements} root cells but asked for all of them"
          cases += 1
        end
      end
    end
    assert_operator cases, :>=, 200
  end

end
