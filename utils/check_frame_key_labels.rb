# Lint: an index a CAFrame verb makes from a key column -- group_by's single
# key, resample's bins, pivot's sorted keys -- is given the key's
# attributes by one part, CAFrame.key_labels (lib/carray/frame/frame.rb).
# resample had built its index by hand and left them behind.  In group.rb
# and reshape.rb, a GroupedFrame index or a key's sorted distinct values
# made without the part is a copy; a line that is not an index from a key
# says so with `key-labels:` on the line or the line above.
#
# Run via `rake frame_key_labels_check`, or `ruby utils/check_frame_key_labels.rb`.

ROOT = File.expand_path("..", __dir__)
FILES = %w[group.rb reshape.rb]
RULE = /\bunique\(|GroupedFrame\.new\(.*\bindex:|@index\s*=\s*index\b/

found = []
FILES.each do |base|
  lines = File.read(File.join(ROOT, "lib", "carray", "frame", base), encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ RULE
    next if l =~ /^\s*#/
    window = lines[i..[i + 2, lines.size - 1].min].join
    next if window.include?("key_labels")
    next if l.include?("key-labels:") || (i > 0 && lines[i - 1].include?("key-labels:"))
    found << "lib/carray/frame/#{base}:#{i + 1}: an index made from a key by hand: use CAFrame.key_labels"
  end
end

if found.empty?
  puts "frame_key_labels_check: ok"
else
  warn "frame_key_labels_check: an index made from a key outside the part:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
