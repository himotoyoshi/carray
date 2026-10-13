# Find memory a raise leaves behind, across every public method.
#
# A C buffer taken before a call that can raise must be released when it
# raises.  The calls that can raise are often not visible where the buffer
# is taken: asking an array for its mask, or for one of its cells, runs
# Ruby when the array is a CAObject.  This tool runs every public CArray
# method that takes no required argument (found by reflection, so a new
# method is covered without being listed), plus a few operations that
# need arguments, over sources whose Ruby hooks raise on demand:
#
#   fetch          the cells are read (copy_data / fetch_addr)
#   mask_fetch     the mask is read (mask_copy_data / mask_fetch_addr)
#   mask_created   the array is asked whether it has a mask
#   create_mask    the array is asked to make its mask
#
# Each (source, hook, method) is called a few times to warm up and CALLS
# times measured, in this process, reading macOS's malloc zone, and so is
# the same call with no hook raising; growth above that control by more
# than the threshold is reported.  A call that builds Ruby objects
# (categorize, source_code) moves by up to ~30 KB either way, and the
# noise grows with the source, so the source stays at 128 KB of data and
# the threshold at 32 KB: a leak of a buffer the size of the data, or of a
# copy of it, stands out; the mask alone (16 KB) does not.  A report is a
# lead to measure again with utils/measure_leak.rb, which runs one
# expression in a fresh process.
#
#   ruby -Iext -Ilib utils/leak_matrix.rb [-t BYTES] [METHOD,...]
#
# Exit status 1 when anything is reported, 2 when the measurement is
# unavailable (not macOS, no Fiddle).

require "carray"
require "optparse"
begin
  require "fiddle"
  STATS = Fiddle::Function.new(Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
                               [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
rescue LoadError, Fiddle::DLError
  warn "measurement unavailable (needs macOS and Fiddle)"
  exit 2
end
exit 2 unless RUBY_PLATFORM =~ /darwin/

threshold = 32768
OptionParser.new { |o| o.on("-t", "--threshold BYTES", Integer) { |v| threshold = v } }.parse!
only = ARGV[0]&.split(",")
$stderr.puts "carray_ext: " + $LOADED_FEATURES.grep(/carray_ext/).first.to_s

def in_use
  b = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
  STATS.call(nil, b)
  b[8, 8].unpack1("Q")
end

N = 1 << 14
CALLS = 50
$hook = nil

class LeakMatrixSource < CAObject
  def initialize (n, masked)
    @masked = masked
    @src = CArray.float64(n).seq
    super(CA_FLOAT64, [n])
    self.mask = 0 if masked
  end
  def mask_created?; $hook == :mask_created ? raise("hook") : @masked; end
  def create_mask; $hook == :create_mask ? raise("hook") : nil; end
  def copy_data (d); raise("hook") if $hook == :fetch; d[] = @src; end
  def fetch_addr (a); raise("hook") if $hook == :fetch; @src[a]; end
  def mask_copy_data (d); raise("hook") if $hook == :mask_fetch; d[] = 0; end
  def mask_fetch_addr (a); $hook == :mask_fetch ? raise("hook") : 0; end
end

HOOKS = [:fetch, :mask_fetch, :mask_created, :create_mask]

SOURCES = {
  "plain"   => -> { LeakMatrixSource.new(N, false) },
  "masked"  => -> { LeakMatrixSource.new(N, true) },
  "block"   => -> { LeakMatrixSource.new(N, true)[0...N - 1] },
  "reshape" => -> { LeakMatrixSource.new(N, true).reshape(256, N / 256) },
}

SKIP = /!\z|\A(each|map|attach|__|inspect|dump|save|object_id|hash\z|freeze|display|
        instance_variable|singleton|pretty|to_enum|enum_for|dup\z|clone\z|tap\z|then\z|
        itself|frozen|seed|random|shuffle|sample|define|extend|debug|read_only|without|
        remove|method\z|methods\z|public_send|send\z|respond|is_a|kind_of|instance_of|
        class\z|yield_self|to_s\z|to_yaml|object)/x

METHODS = CArray.public_instance_methods.select { |m|
  a = CArray.public_instance_method(m).arity
  (a == 0 || a == -1) && m.to_s !~ SKIP
}.sort.map { |m| [m.to_s, ->(v) { v.send(m) }] }

WITH_ARGUMENTS = {
  "to_type(:float32)" => ->(v) { v.to_type(:float32) },
  "+ 1"               => ->(v) { (v + 1).copy },
  "[index]"           => ->(v) { v[CArray.int64(N / 2).seq] },
  "[index, nil]"      => ->(v) { v.ndim == 2 ? v[CArray.int64(128).seq, nil] : v[CArray.int64(N / 2).seq] },
  "sum(axis: 0)"      => ->(v) { v.sum(axis: 0) },
  "lazy * 2"          => ->(v) { (v.lazy * 2).copy },
  "stack"             => ->(v) { CArray.stack([v, v]).copy },
  "meld"              => ->(v) { CArray.meld(v, v).copy },
  "tile"              => ->(v) { v.ndim == 2 ? v.tile(2, 1).copy : v.tile(2).copy },
  "roll"              => ->(v) { v.ndim == 2 ? v.roll(1, 1).copy : v.roll(1).copy },
  "fake"              => ->(v) { v.fake(CA_INT64).copy },
  "[boolean]"         => ->(v) { v[v.value > 3].copy },
  "from_memory_view"  => ->(v) { CArray.from_memory_view(v) },
  "sort(axis: 0)"     => ->(v) { v.sort(axis: 0).copy },
}

ops = METHODS + WITH_ARGUMENTS.to_a
ops = ops.select { |name, _| only.include?(name) } if only

# Bytes per call of op over a fresh source, with the given hook raising
# (nil: none raises).
def bytes_per_call (make, hook, op)
  run = -> {
    $hook = nil
    v = make.()
    $hook = hook
    begin
      op.(v)
    rescue Exception
    ensure
      $hook = nil
    end
  }
  3.times { run.() }
  GC.start
  before = in_use
  CALLS.times { run.() }
  GC.start
  (in_use - before).fdiv(CALLS)
end

found = []
SOURCES.each do |sname, make|
  HOOKS.each do |hook|
    ops.each do |name, op|
      grown = bytes_per_call(make, hook, op) - bytes_per_call(make, nil, op)
      found << [grown, sname, hook, name] if grown > threshold
    end
  end
end

found.sort.reverse.each { |g, s, h, n| printf("%10.0f B/call  %-8s %-13s %s\n", g, s, h, n) }
puts "leak_matrix: #{ops.size} operations x #{SOURCES.size} sources x #{HOOKS.size} hooks, #{found.size} above the control by #{threshold} B/call"
exit(found.empty? ? 0 : 1)
