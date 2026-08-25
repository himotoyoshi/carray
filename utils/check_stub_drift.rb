# Drift check between yard-stubs/ and the live C extension.
#
# For every (class, method) declared in yard-stubs/**/*.rb:
#   - ERROR if the method does not exist on the live class
#     (the stub documents a phantom).
#
# For every (class, method) defined on the live CArray-family classes:
#   - INFO if no stub covers it yet (uncovered surface; expected
#     during the per-file sweep).
#
# Run via: `rake stub_check` (or directly with `ruby -I lib -I ext
# utils/check_stub_drift.rb`).

require "prism"

STUB_DIR = File.expand_path("../yard-stubs", __dir__)

# Classes whose surface we track. A stub may open any of these; the
# runtime side reads instance_methods(false) and singleton_methods
# from each. Uncovered methods on these are reported in the coverage
# table (the yard-stub sweep is expected to reach 100%).
TRACKED_CLASSES = %w[
  CA
  CArray CScalar CAWrap CAView CAStride CARefer CABlock CARepeat
  CATranspose CAFarray CAField CASelect CAObject CAReduce CAWindow
  CAShift CAGrid CAMapping CAFake CABitarray CABitfield
  CATile CARoll CAByteSwap
  CAUnboundRepeat CAStack CAMeld CARecord
  UndefClass
  CAMath
]

# Modules shared with Ruby core that carray only extends with a handful
# of methods (e.g. the global `CA_*` cast shorthands installed on Kernel
# via rb_define_global_function). Stubs against these are phantom-checked
# like everything else, but their live surface is dominated by Ruby
# builtins that carray neither owns nor stubs, so they are omitted from
# the coverage table.
PHANTOM_ONLY_CLASSES = %w[
  Kernel
]

# --- 1. Parse stubs ---------------------------------------------------------

StubMethod = Struct.new(:klass, :name, :singleton, :file, :line)

def parse_stub_file(path)
  out = []
  src = File.read(path)
  ast = Prism.parse(src).value
  walk(ast, [], false, path, out)
  out
end

def walk(node, klass_stack, singleton, path, out)
  case node
  when Prism::ClassNode
    name = const_name(node.constant_path)
    walk_children(node.body, klass_stack + [name], singleton, path, out)
  when Prism::ModuleNode
    name = const_name(node.constant_path)
    walk_children(node.body, klass_stack + [name], singleton, path, out)
  when Prism::SingletonClassNode
    walk_children(node.body, klass_stack, true, path, out)
  when Prism::DefNode
    return if klass_stack.empty?
    klass = klass_stack.join("::")
    is_singleton = singleton || !node.receiver.nil?
    out << StubMethod.new(klass, node.name.to_s, is_singleton, path,
                          node.location.start_line)
  else
    walk_children(node, klass_stack, singleton, path, out) if node.respond_to?(:child_nodes)
  end
end

def walk_children(node, klass_stack, singleton, path, out)
  return unless node
  node.child_nodes.compact.each do |child|
    walk(child, klass_stack, singleton, path, out)
  end
end

def const_name(node)
  case node
  when Prism::ConstantReadNode then node.name.to_s
  when Prism::ConstantPathNode
    [const_name(node.parent), node.name.to_s].compact.join("::")
  end
end

stubs = Dir.glob(File.join(STUB_DIR, "**/*.rb")).flat_map { |f| parse_stub_file(f) }

# --- 2. Load library and collect live methods ------------------------------

require "carray"

live = {}
(TRACKED_CLASSES + PHANTOM_ONLY_CLASSES).each do |cname|
  klass = cname.split("::").inject(Object) do |scope, c|
    break nil unless scope.const_defined?(c, false)
    scope.const_get(c)
  end
  next unless klass
  # Union public + private instance methods so constructor pairs
  # (initialize / initialize_copy) and dunder helpers can be stubbed.
  instance = klass.instance_methods(false) +
             klass.private_instance_methods(false)
  live[cname] = {
    instance: instance.map(&:to_s).to_set,
    singleton: klass.singleton_methods(false).map(&:to_s).to_set,
  }
end

# --- 3. Cross-check --------------------------------------------------------

errors = []
covered = Hash.new { |h, k| h[k] = { instance: Set.new, singleton: Set.new } }

stubs.each do |m|
  unless live.key?(m.klass)
    errors << "#{m.file}:#{m.line}: unknown class `#{m.klass}` " \
              "(not in TRACKED_CLASSES / PHANTOM_ONLY_CLASSES, or not loaded)"
    next
  end
  bucket = m.singleton ? :singleton : :instance
  unless live[m.klass][bucket].include?(m.name)
    errors << "#{m.file}:#{m.line}: " \
              "#{m.klass}#{m.singleton ? '.' : '#'}#{m.name} " \
              "is documented but not defined in the C extension"
    next
  end
  covered[m.klass][bucket] << m.name
end

# --- 4. Report --------------------------------------------------------------

if errors.any?
  puts "DRIFT: #{errors.size} phantom method(s) in yard-stubs/"
  errors.each { |e| puts "  #{e}" }
else
  puts "OK: every stub method exists on the live class."
end

puts
puts "Coverage (stubbed / live):"
printf "  %-22s   %-13s %-13s\n", "", "instance", "singleton"
TRACKED_CLASSES.each do |cname|
  next unless live[cname]
  ti = live[cname][:instance].size
  si = covered[cname][:instance].size
  ts = live[cname][:singleton].size
  ss = covered[cname][:singleton].size
  next if (ti + ts).zero? && (si + ss).zero?
  marker = (si == ti && ss == ts) ? "✓" : " "
  printf "  %s %-22s %4d / %4d   %4d / %4d\n", marker, cname, si, ti, ss, ts
end

exit(errors.empty? ? 0 : 1)
