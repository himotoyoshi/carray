# Lint: a Ruby value is not narrowed into an integer cell by a C cast.
#
# A value stored into an integer cell must fit the cell's type; one that
# does not raises RangeError (ca_obj2integer_fitting, carray_cast.c, which
# the generated store readers call).  A C cast of the value's long --
#
#   (int8_t) FIX2LONG(v)   (uint16_t) NUM2LONG(v)   (int32_t) OBJ2LONG(v)
#
# -- wraps it instead (300 into int8 is 44).  This check finds such a cast
# and requires a note, in a comment on the same line or the line above, of
# the form
#
#   /* fits: <why the value is known to fit> */
#
# The generated carray_kernels_*.c and carray_cast_func.c are not read (their
# generators call ca_obj2integer_fitting).
#
# Run via `rake integer_store_check`, or
# `ruby utils/check_integer_store_narrowing.rb [paths]`.

ROOT = File.expand_path("..", __dir__)
CAST = /\(\s*u?int(?:8|16|32)_t\s*\)\s*(?:FIX2LONG|NUM2LONG|NUM2INT|NUM2UINT|NUM2ULONG|NUM2LL|NUM2ULL|OBJ2LONG|OBJ2ULONG|OBJ2LL|OBJ2ULL|rb_obj2\w+|rb_num2\w+)\s*\(\s*(?!ca_obj2integer_fitting)/
NOTE = /fits:\s*\S/

def sites (path)
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index.filter_map do |line, i|
    next unless line =~ CAST
    next if line =~ %r{^\s*(?:/\*|//|\*(?:\s|/|$))}
    noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
    [i + 1, line.strip] unless noted
  end
end

paths =
  if ARGV.empty?
    Dir.chdir(ROOT) { Dir["ext/*.c"].sort.reject { |p| p =~ %r{/carray_kernels_|/carray_cast_func\.c} } }
       .map { |p| File.join(ROOT, p) }
  else
    ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, "**", "*.c")].sort : [a] }
  end

offenders = paths.flat_map { |p| sites(p).map { |s| [p.sub("#{ROOT}/", ""), *s] } }

if offenders.empty?
  puts "integer_store_check: no Ruby value is narrowed into an integer cell by a cast"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "integer_store_check: #{offenders.size} cast(s) that can wrap a Ruby value."
puts "Read the value with ca_obj2integer_fitting (carray_internal.h), or say"
puts "why it fits:"
puts "  /* fits: checked against INT8_MIN..INT8_MAX above */"
exit 1
