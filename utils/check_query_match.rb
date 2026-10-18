# Lint: the type a value query meets a reference in is decided by one part.
#
# count(v), the search family, is_in, the set operations, locate_addr and
# the joining of arrays compare the values of a query with a reference.
# The type they compare in is decided by
#
#   ca_query_match_type(ref_type, query)   ext/carray_cast.c (C)
#   query_match_type(query)                its private Ruby method
#
# which folds the common type (ca_promote_type / ca_promote_scalar_type)
# and widens it for values (ca_value_match_type).  This check finds a call
# site that composes those itself --
#
#   C     ca_value_match_type(...) / ca_promote_scalar_type(...) outside
#         ext/carray_cast.c
#   Ruby  value_match_type(CArray.result_type(...)) or
#         value_match_type(..., x.data_type)
#
# -- and requires a note on the same line or the line above:
#
#   /* match: <why this place decides it itself> */   (C)
#   # match: <why this place decides it itself>       (Ruby)
#
# Run via `rake query_match_check`, or `ruby utils/check_query_match.rb`.

ROOT = File.expand_path("..", __dir__)

C_CALL    = /\b(?:ca_value_match_type|ca_promote_scalar_type)\s*\(/
RUBY_CALL = /\bvalue_match_type\s*\(\s*(?:CArray\.result_type|[^)]*data_type)/
NOTE      = /match:\s*\S/
COMMENT_C = %r{\A\s*(?:/\*|//|\*(?:\s|/|$))}

def noted? (lines, i)
  lines[i] =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
end

offenders = []
Dir.chdir(ROOT) do
  (Dir["ext/*.c"] + Dir["ext/*.h"] + ["ext/mkkernel.rb"]).sort.each do |path|
    next if path =~ %r{/carray_kernels_|/carray_cast\.c\z|/carray_internal\.h\z}
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next if line =~ COMMENT_C
      next unless line =~ C_CALL
      offenders << [path, i + 1, line.strip] unless noted?(lines, i)
    end
  end
  Dir["lib/**/*.rb"].sort.each do |path|
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next if line =~ /\A\s*#/
      next unless line =~ RUBY_CALL
      offenders << [path, i + 1, line.strip] unless noted?(lines, i)
    end
  end
end

if offenders.empty?
  puts "query_match_check: every value query meets its reference through the part"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "query_match_check: #{offenders.size} place(s) decide a query's type by hand."
puts "Use ca_query_match_type (C) / query_match_type (Ruby), or say why:"
puts "  /* match: ... */   # match: ..."
exit 1
