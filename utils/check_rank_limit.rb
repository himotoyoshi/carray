# Lint: an array has at most CA_RANK_MAX axes, and a rank given or computed
# is held to that by one part, ca_check_rank_fits (ext/carray_utils.c),
# before a single dim[] is written.  Inside the library the constructors
# use CA_CHECK_RANK_GIVEN (carray_internal.h), which calls it; the public
# CA_CHECK_RANK stays for extensions.
#
# A rank compared with CA_RANK_MAX by hand is a second copy, and the copies
# had drifted: one was a level off and wrote past a dim[] on the stack, and
# one was missing, so CArray.stack built an array of CA_RANK_MAX + 1 axes.
# A count that is not an array's rank (bundles, indices, a list of axes)
# is not this rule; a line that compares one says so with `rank-check:`.
# Only a comparison in an `if` is read: a loop bound or a CA_ASSUME states
# what is already known rather than checking it.
#
# The generated carray_kernels_*.c are not read; ext/mkkernel.rb is.
#
# Run via `rake rank_limit_check`, or `ruby utils/check_rank_limit.rb`.

ROOT = File.expand_path("..", __dir__)
ALLOWED = %w[carray_utils.c carray_internal.h carray.h]

RULES = [
  [/\bCA_CHECK_RANK\s*\(/,
   "CA_CHECK_RANK: use CA_CHECK_RANK_GIVEN, which names the method"],
  [/\bif\s*\(.*(?:[<>]=?\s*CA_RANK_MAX\b|\bCA_RANK_MAX\s*[<>]=?)/,
   "a rank compared with CA_RANK_MAX by hand: use ca_check_rank_fits (a count that is not a rank says so with rank-check:)"],
]

files = Dir[File.join(ROOT, "ext", "*.{c,h}")].reject { |f| File.basename(f).start_with?("carray_kernels_") }
files << File.join(ROOT, "ext", "mkkernel.rb")

found = []
files.each do |path|
  next if ALLOWED.include?(File.basename(path))
  lines = File.binread(path).lines
  lines.each_with_index do |l, i|
    # a comparison split over two lines carries its note on either
    ctx = l + (lines[i - 1] || "")
    RULES.each do |re, hint|
      next unless l =~ re
      next if re.source.include?("CA_RANK_MAX") && ctx.include?("rank-check:")
      found << "#{path.sub(ROOT + '/', '')}:#{i + 1}: #{hint}"
    end
  end
end

if found.empty?
  puts "rank_limit_check: ok"
else
  warn "rank_limit_check: a rank checked outside ca_check_rank_fits:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
