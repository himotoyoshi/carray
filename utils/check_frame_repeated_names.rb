# Lint: column names a CAFrame verb makes or takes are checked for a repeat
# by one part, CAFrame.refuse_repeated_names (lib/carray/frame/frame.rb), or
# through CAFrame#column_keys for a list of names a verb takes.  Eleven
# checks had been written by hand, each in its own words, and the verbs that
# take columns had none.  A repeat found by hand -- tally, uniq.size, a
# count above one -- outside the part is a copy; a check of something that
# is not a list of column names says so with `names-check:` on the line or
# the line above.
#
# Run via `rake frame_repeated_names_check`, or `ruby utils/check_frame_repeated_names.rb`.

ROOT = File.expand_path("..", __dir__)
PART = "frame.rb"
RULE = /\.tally\b|\.uniq\.(size|length)\b|\.count\([^)]*\)\s*>\s*1/

found = []
Dir[File.join(ROOT, "lib", "carray", "frame", "*.rb")].sort.each do |path|
  base = File.basename(path)
  lines = File.read(path, encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ RULE
    next if l =~ /^\s*#/
    next if l.include?("names-check:") || (i > 0 && lines[i - 1].include?("names-check:"))
    next if base == PART && lines[[i - 3, 0].max..i].join.include?("refuse_repeated_names")
    found << "lib/carray/frame/#{base}:#{i + 1}: a repeat found by hand: use CAFrame.refuse_repeated_names (or column_keys)"
  end
end

if found.empty?
  puts "frame_repeated_names_check: ok"
else
  warn "frame_repeated_names_check: a repeated name checked outside the part:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
