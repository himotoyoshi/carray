# Lint: a column name a CAFrame verb is given is a String, and anything else
# is refused by one part, CAFrame.column_key (lib/carray/frame/frame.rb),
# with TypeError "<verb>: a column name is a String (got :x)".  CAFrame.new,
# cast, to_frame, from_csv and the readers' missing: had each refused a
# Symbol by hand, in their own words and with ArgumentError or TypeError.
# A refusal that says a name must be a String, written outside the part, is
# a copy.
#
# Run via `rake frame_column_names_check`, or `ruby utils/check_frame_column_names.rb`.

ROOT = File.expand_path("..", __dir__)
PART = "frame.rb"
RULE = /is a String|column names \(Strings\)|Symbols are reserved/

found = []
Dir[File.join(ROOT, "lib", "carray", "frame", "*.rb")].sort.each do |path|
  base = File.basename(path)
  lines = File.read(path, encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ RULE
    next if l =~ /^\s*#/
    next if base == PART && lines[[i - 6, 0].max..i].join.include?("def self.column_key")
    found << "lib/carray/frame/#{base}:#{i + 1}: a column name checked by hand: use CAFrame.column_key"
  end
end

if found.empty?
  puts "frame_column_names_check: ok"
else
  warn "frame_column_names_check: a column name checked outside the part:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
