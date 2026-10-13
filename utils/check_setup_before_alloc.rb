# Lint: a constructor checks its arguments before it allocates.
#
# A constructor allocates a struct and fills it with a *_setup function.
# When the setup rejects an argument after the allocation, the struct is
# lost: no Ruby object owns it yet.  The convention is that *_setup(NULL,
# ...) runs the checks only and returns, so the constructor calls it first:
#
#   ca_foo_setup(NULL, parent, n);
#   ca = (CAFoo *) ca_array_alloc(CA_OBJ_FOO, ndim);
#   ca_foo_setup(ca, parent, n);
#
# This check finds a function that allocates a struct (ca_array_alloc,
# ALLOC(CFoo), ALLOC_N(CFoo, 1)) and then calls a *_setup on it, and
# requires either a *_setup(NULL, ...) before the allocation or a note, in
# a comment on the allocation's line or the line above, of the form
#
#   /* check: <why nothing the setup checks can fail here> */
#
# The generated carray_kernels_*.c are not read.  Run via
# `rake setup_before_alloc_check`, or `ruby utils/check_setup_before_alloc.rb
# [paths]`.

ROOT  = File.expand_path("..", __dir__)
ALLOC = /\bca_array_alloc\s*\(|\bALLOC\s*\(\s*C[A-Z]\w*\s*\)|\bALLOC_N\s*\(\s*C[A-Z]\w*\s*,\s*1\s*\)/
SETUP = /\b\w+_setup\w*\s*\(\s*(?!NULL\b)/
NULL_SETUP = /\b\w+_setup\w*\s*\(\s*NULL\b/
NOTE  = /check:\s*\S/

def functions (lines)
  out = []
  name = nil
  start = nil
  depth = 0
  lines.each_with_index do |line, i|
    if depth == 0 && line =~ /^([A-Za-z_]\w*)\s*\(/
      name, start = Regexp.last_match(1), i
    end
    depth += line.count("{") - line.count("}")
    if depth == 0 && start && line =~ /^\}/
      out << [name, start, i]
      start = nil
    end
  end
  out
end

def sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  functions(lines).filter_map do |name, from, to|
    body = lines[from..to]
    a = body.index { |l| l =~ ALLOC && l !~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))} } or next
    next unless body[(a + 1)..].any? { |l| l =~ SETUP }
    next if body[0...a].any? { |l| l =~ NULL_SETUP }
    noted = body[a] =~ NOTE || (a > 0 && body[a - 1] =~ NOTE)
    [from + a + 1, name, body[a].strip] unless noted
  end
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, "**", "*.c")].sort : [a] }
  end

offenders = paths.flat_map { |p| sites(p).map { |s| [p.sub("#{ROOT}/", ""), *s] } }

if offenders.empty?
  puts "setup_before_alloc_check: every constructor checks before it allocates"
  exit 0
end

offenders.each { |path, line, fn, text| puts "#{path}:#{line}: [#{fn}] #{text}" }
puts
puts "setup_before_alloc_check: #{offenders.size} constructor(s) allocate before their checks."
puts "Call the setup with NULL first (it checks and returns), or say why"
puts "nothing it checks can fail:"
puts "  /* check: the setup does not raise */"
exit 1
