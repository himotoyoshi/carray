# Lint: a step that can raise is undone through a part.
#
# When a step that can raise runs after something was taken -- a buffer, a
# new array, an attach -- what was taken has to be given back if the step
# raises.  The parts (carray_internal.h) do that:
#
#   ca_fill_or_free    frees a new array
#   ca_fill_or_xfree   frees a buffer that belongs to nothing yet
#   ca_fill_or_detach  detaches the arrays attached for the step
#   ca_attach_window   opens and closes attach windows (carray_core.c)
#   ca_iter_ensure     closes kernel iterator walks
#
# This check finds a hand-written rb_protect outside the files that
# implement the parts, and requires a note, in a comment on the same line
# or the line above, of the form
#
#   /* protect: <why it is not one of the parts> */
#
# e.g. "protect: converts the caller's value; nothing is held".
#
# The generated carray_kernels_*.c are not read.  Run via
# `rake protect_parts_check`, or `ruby utils/check_protect_parts.rb [paths]`.

ROOT = File.expand_path("..", __dir__)
CALL = /\brb_protect\s*\(/
NOTE = /protect:\s*\S/

EXEMPT_FILES = %w[
  ext/carray_copy.c
  ext/carray_core.c
  ext/ca_kernel_iterator.c
  ext/ca_sweep_engine.c
]

def sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index.filter_map do |line, i|
    next unless line =~ CALL
    next if line =~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))}
    noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
    [i + 1, line.strip] unless noted
  end
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) {
      Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} || EXEMPT_FILES.include?(p) }
    }.map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, "**", "*.c")].sort : [a] }
  end

offenders = paths.flat_map { |p| sites(p).map { |s| [p.sub("#{ROOT}/", ""), *s] } }

if offenders.empty?
  puts "protect_parts_check: every hand-written rb_protect says why"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "protect_parts_check: #{offenders.size} hand-written rb_protect without a note."
puts "Use ca_fill_or_free / ca_fill_or_xfree / ca_fill_or_detach (carray_internal.h),"
puts "or say why the step is not one of them:"
puts "  /* protect: converts the caller's value; nothing is held */"
exit 1
