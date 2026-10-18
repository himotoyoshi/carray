# Lint: a key a CAFrame verb takes (group_by, is_duplicate, sort_by_key,
# join, join_asof, align, pivot, resample, stack_rows, windows) is read by
# one part, CAFrame#key_column (lib/carray/frame/group.rb): a column of that
# name, or the index by the row axis name, or a CArray, one value per row.
# The verbs had read their keys themselves, and drifted: join and join_asof
# could not take the index, and an N-D key was refused in five wordings.  A
# key looked up by hand -- the index picked by the row axis name, or a
# refusal saying "not one value per row" -- outside the part is a copy; a
# line that picks the index for another reason says so with `keys-check:`.
#
# Run via `rake frame_keys_check`, or `ruby utils/check_frame_keys.rb`.

ROOT = File.expand_path("..", __dir__)
RULES = [
  [/not one value per row/, "a key refused by hand: read it with key_column"],
  [/(?:next|return)\s+@index\s+if\s+@index|\?\s*@index\s*:/, "the index picked as a key by hand: read it with key_column"],
]

found = []
Dir[File.join(ROOT, "lib", "carray", "frame", "*.rb")].sort.each do |path|
  base = File.basename(path)
  lines = File.read(path, encoding: "UTF-8").lines
  inside = false
  lines.each_with_index do |l, i|
    inside = true if base == "group.rb" && l =~ /def key_column\b/
    inside = false if inside && l =~ /^  end\b/
    next if inside || l =~ /^\s*#/
    next if l.include?("keys-check:") || (i > 0 && lines[i - 1].include?("keys-check:"))
    RULES.each do |re, hint|
      found << "lib/carray/frame/#{base}:#{i + 1}: #{hint}" if l =~ re
    end
  end
end

if found.empty?
  puts "frame_keys_check: ok"
else
  warn "frame_keys_check: a key read outside key_column:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
