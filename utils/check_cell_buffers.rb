# Lint: a buffer for an array's cells is valid before anything can mark it.
#
# Object cells are VALUEs, and ca_mark marks a view's ca->ptr strictly
# (rb_gc_mark, which trusts what it is given) from the moment the pointer is
# set.  A fresh buffer that is published before it is filled must therefore
# already hold valid VALUEs, whether or not the code that fills it can call
# Ruby today.  ca_alloc_cells (carray_internal.h) allocates such a buffer:
# object cells start as nil.  This check finds a ptr assigned straight from
# an allocator,
#
#   ->ptr = xmalloc(   ->ptr = ALLOC_N(   ->ptr = xcalloc(   ...
#
# and requires either ca_alloc_cells or a note, in a comment on the same line
# or the line above, of the form
#
#   /* cells: <why the cells are valid before anything can mark them> */
#
# The generated carray_kernels_*.c are not read.
#
# Run via `rake cell_buffer_check`, or `ruby utils/check_cell_buffers.rb`.
# Given paths (files, or directories searched for *.c), it checks those
# instead -- a C extension built on carray can run it on its own sources.

ROOT = File.expand_path("..", __dir__)

ASSIGN = /->\s*ptr\s*=\s*(?:\([^)]*\)\s*)?(?:xmalloc|xmalloc2|xcalloc|xrealloc|ALLOC_N|ALLOC|malloc|calloc|realloc|ruby_xmalloc)\s*\(/
NOTE   = /cells:\s*\S/

def sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index.filter_map do |line, i|
    next unless line =~ ASSIGN
    next if line =~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))}
    noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
    [i + 1, line.strip] unless noted
  end
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |arg| File.directory?(arg) ? Dir[File.join(arg, "**", "*.c")].sort : [arg] }
  end

offenders = paths.flat_map { |path| sites(path).map { |site| [path.sub("#{ROOT}/", ""), *site] } }

if offenders.empty?
  puts "cell_buffer_check: every cell buffer is valid before it is published"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "cell_buffer_check: #{offenders.size} buffer(s) assigned to ptr straight from an allocator."
puts "Allocate an array's cells with ca_alloc_cells (object cells start as nil),"
puts "or say why the cells are valid before anything can mark them:"
puts "  /* cells: set to 0 below */"
exit 1
