# Lint: a C pointer into a name or a String the collector can move is not
# kept past the expression that reads it.
#
# rb_obj_classname, rb_class2name and rb_id2name return pointers into
# Strings that no local VALUE holds.  Any allocation can compact the heap
# (with GC.auto_compact) and move such a String, and rb_raise / rb_sprintf
# allocate their message before they read a %s argument.  The same holds for
# RSTRING_PTR of a String just made by a call, which nothing holds at all.
# Pass the VALUE with "%"PRIsVALUE instead: rb_obj_class(x) for a class
# name, the class itself for rb_class2name, rb_id2str(id) for an ID.
#
# This check finds every call of those three functions, and RSTRING_PTR /
# StringValuePtr / StringValueCStr of a call, and requires each to carry a
# note, in a comment on the same line or the line above, of the form
#
#   /* name: <why the pointer is not kept> */
#
# e.g. "name: read at once by strlen".
#
# The generated carray_kernels_*.c are not read.
#
# Run via `rake name_pointer_check`, or `ruby utils/check_name_pointers.rb`.
# Given paths (files, or directories searched for *.c), it checks those
# instead.

ROOT = File.expand_path("..", __dir__)

CALL = /\b(?:rb_obj_classname|rb_class2name|rb_id2name)\s*\(|\b(?:RSTRING_PTR|StringValuePtr|StringValueCStr)\s*\(\s*rb_\w+\s*\(/
NOTE = /name:\s*\S/

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
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |arg| File.directory?(arg) ? Dir[File.join(arg, "**", "*.c")].sort : [arg] }
  end

offenders = paths.flat_map { |path| sites(path).map { |site| [path.sub("#{ROOT}/", ""), *site] } }

if offenders.empty?
  puts "name_pointer_check: no name pointer is kept past its expression"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "name_pointer_check: #{offenders.size} pointer(s) into a String the collector can move."
puts "Pass the VALUE with \"%\"PRIsVALUE (rb_obj_class(x), the class, rb_id2str(id)),"
puts "or say why the pointer is not kept:"
puts "  /* name: read at once by strlen */"
exit 1
