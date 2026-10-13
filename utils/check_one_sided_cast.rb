# Lint: two operands meet at a type decided by the canonical routes.
#
# Casting a negotiable operand to its peer's data type -- one side chosen by
# hand -- truncates whenever the peer is the narrower one (1.5 against an
# int32 array becomes 1 and matches).  The routes decide the common type
# instead (docs/authoring/CastAndPromote.md): CArray.result_type (widened by
# value_match_type where values are matched) then to_type on both, binop
# coercion for a op b, promote_list for N arrays, and wrap_readonly /
# wrap_writable for a fixed target that the operation itself requires
# (float64, CA_SIZE, boolean).
#
# This check finds a conversion whose target is some array's data type --
#
#   Ruby  x.to_type(y.data_type)   x.as_type(data_type)
#         CArray.wrap_readonly(x, @counts_data_type)
#   C     rb_ca_wrap_readonly(v, INT2NUM(ca->data_type))   rb_ca_to_type(v, ...)
#
# -- and requires a note, in a comment on the same line or the line above:
#
#   # coerce: <why this side is the authority>      (Ruby)
#   /* coerce: <why this side is the authority> */  (C)
#
# e.g. "coerce: a store into the receiver" or "coerce: the type promote_list
# chose".  ext/carray_cast.c, which implements the routes, is not read, nor
# are the generated carray_kernels_*.c.
#
# Run via `rake one_sided_cast_check`, or `ruby utils/check_one_sided_cast.rb`.

ROOT = File.expand_path("..", __dir__)

RUBY_CALL = /\b(?:to_type|as_type)\([^)]*data_type|wrap_(?:readonly|writable)\([^,)]+,[^)]*data_type/
C_CALL    = /\b(?:rb_ca_wrap_readonly|rb_ca_wrap_writable|ca_wrap_readonly|rb_ca_to_type)\s*\([^;]*data_type/
NOTE      = /coerce:\s*\S/

def sites (path, call, comment)
  lines = File.readlines(path, encoding: "UTF-8")
  lines.each_with_index.filter_map do |line, i|
    next unless line =~ call
    next if line =~ comment
    noted = line =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
    [i + 1, line.strip] unless noted
  end
end

offenders = []
Dir.chdir(ROOT) do
  Dir["lib/**/*.rb"].sort.each do |p|
    sites(p, RUBY_CALL, /^\s*#/).each { |s| offenders << [p, *s] }
  end
  Dir["ext/*.c"].sort.each do |p|
    next if p =~ %r{/carray_kernels_|/carray_cast\.c\z}
    sites(p, C_CALL, %r{^\s*(?:/\*|//|\*(?:\s|/|$))}).each { |s| offenders << [p, *s] }
  end
end

if offenders.empty?
  puts "one_sided_cast_check: every cast to an array's data type says why"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "one_sided_cast_check: #{offenders.size} cast(s) to an array's data type."
puts "Settle a common type with CArray.result_type (or let the binop coerce),"
puts "or say why this side is the authority:"
puts "  # coerce: a store into the receiver"
exit 1
