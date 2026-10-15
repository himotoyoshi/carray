# Lint: where a person reads an array's type, a Face is named through one
# part, CArray::Inspector.type_label (lib/carray/inspect.rb).  "face? ?
# class : data_type" written by hand named the same Face differently in
# different messages.  Such a choice outside the inspector is a copy; a
# line that chooses for another reason (a value, not a name) says so with
# `type-label:`.
#
# Run via `rake type_label_check`, or `ruby utils/check_type_label.rb`.

ROOT = File.expand_path("..", __dir__)
RULE = /face\?\s*\?[^:\n]*(\.class\b|face_label)/

found = []
Dir[File.join(ROOT, "lib", "**", "*.rb")].sort.each do |path|
  next if path.end_with?("lib/carray/inspect.rb")
  File.read(path, encoding: "UTF-8").each_line.with_index(1) do |l, n|
    next if l =~ /^\s*#/ || l.include?("type-label:")
    found << "#{path.sub(ROOT + '/', '')}:#{n}: a Face named by hand: use CArray::Inspector.type_label" if l =~ RULE
  end
end

if found.empty?
  puts "type_label_check: ok"
else
  warn "type_label_check: a type named outside CArray::Inspector.type_label:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
