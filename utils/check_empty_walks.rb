# Lint: an odometer walk says how it skips an empty extent.
#
# A walk written as `while (1) { ...cell...; carry ++idx[k] < n ...; }`
# handles its first cell before it looks at any count, so over an extent of
# length 0 it reads and writes one row of cells that are not there.  The
# binary and unary operators did exactly that (an empty array plus a row
# broadcast to it wrote past the result, or crashed).  The answer is a check
# before the walk -- an empty request returns, an entry returns on a
# zero-element result, a caller does it for every slot -- and the walk has
# to say which, in a comment on the loop line or the three lines above it:
#
#   /* empty: the slot returns on an empty region at its entry */
#
# Run via `rake empty_walk_check`, or `ruby utils/check_empty_walks.rb`.
# The generated carray_kernels_*.c are not read.

ROOT = File.expand_path("..", __dir__)

LOOP  = /\bwhile\s*\(\s*1\s*\)|\bfor\s*\(\s*;\s*;\s*\)/
CARRY = /\+\+\s*\w+\s*\[\s*\w+\s*\]\s*</
NOTE  = /empty:\s*\S/

offenders = []
Dir.chdir(ROOT) do
  Dir["ext/*.c"].sort.each do |path|
    next if path.include?("/carray_kernels_")
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next unless line =~ LOOP
      body = lines[i + 1, 40] || []
      depth = line.count("{") - line.count("}")
      carry = false
      body.each do |b|
        carry ||= b =~ CARRY
        depth += b.count("{") - b.count("}")
        break if depth <= 0
      end
      next unless carry
      noted = lines[[i - 3, 0].max..i].any? { |l| l =~ NOTE }
      offenders << [path, i + 1, line.strip] unless noted
    end
  end
end

if offenders.empty?
  puts "empty_walk_check: every odometer walk says how it skips an empty extent"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "empty_walk_check: #{offenders.size} walk(s) handle a first cell before any count."
puts "Check for an empty extent before the walk, and say where:"
puts "  /* empty: the slot returns on an empty region at its entry */"
exit 1
