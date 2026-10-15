# Lint: a frame-wide verb over the columns (group reductions and transforms,
# windowed reductions) runs through CAFrame::ColumnVerbs
# (lib/carray/frame/column_verbs.rb): which columns take part, the shape of
# the answer, and whether a column's type has the operation -- a probe on
# its first row whose refusal reads "not this type".  Each verb had kept its
# own copy, and they drifted: a window left out an N-D column a group
# computed, and a named column was refused with a different exception class
# by different verbs.  A probe of its own (a rescue of the core's refusal
# that answers false) or a refusal reading "has no <verb>" written outside
# the part is a copy.
#
# Run via `rake frame_column_verbs_check`, or `ruby utils/check_frame_column_verbs.rb`.

ROOT = File.expand_path("..", __dir__)
PART = "column_verbs.rb"

RULES = [
  [/rescue\s+CArray::DataTypeError\s*,\s*TypeError\s*,\s*ArgumentError\s*\n\s*false/m,
   "a type probe of its own: use CAFrame::ColumnVerbs#column_has?"],
  [/has no (windowed )?#\{/,
   "a refusal of a named column written by hand: use CAFrame::ColumnVerbs#over_named_columns"],
]

found = []
Dir[File.join(ROOT, "lib", "carray", "frame", "*.rb")].sort.each do |path|
  next if File.basename(path) == PART
  text = File.read(path, encoding: "UTF-8")
  RULES.each do |re, hint|
    text.scan(re) do
      line = text[0, Regexp.last_match.begin(0)].count("\n") + 1
      found << "lib/carray/frame/#{File.basename(path)}:#{line}: #{hint}"
    end
  end
end

if found.empty?
  puts "frame_column_verbs_check: ok"
else
  warn "frame_column_verbs_check: a column verb rule written outside CAFrame::ColumnVerbs:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
