# Lint: the length a match by distance is limited by -- tolerance: of
# locate_nearest_addr, before: / after: / interval: of a key window -- is
# read by one part, CArray::DistanceLimit (lib/carray/distance_limit.rb).
# The two had each read it by hand and took different values: tolerance:
# took NaN and a negative length that a window refused, and a duration
# String was parsed in three places.  In the files that match by
# distance, reading a duration String or checking a length by hand is a
# copy.
#
# Run via `rake distance_limit_check`, or `ruby utils/check_distance_limit.rb`.

ROOT = File.expand_path("..", __dir__)
FILES = %w[lib/carray/key_windows.rb lib/carray/methods/locate_addr.rb
           lib/carray/methods/align_addr.rb lib/carray/frame/join.rb lib/carray/frame/windows.rb]
RULE = /Resolution\.parse\(|not below 0|is a duration|needs a duration|takes widths|nan\?/

found = []
FILES.each do |rel|
  lines = File.read(File.join(ROOT, rel), encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ RULE
    next if l =~ /^\s*#/
    found << "#{rel}:#{i + 1}: a distance limit read by hand: use CArray::DistanceLimit.read"
  end
end

if found.empty?
  puts "distance_limit_check: ok"
else
  warn "distance_limit_check: a distance limit read outside the part:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
