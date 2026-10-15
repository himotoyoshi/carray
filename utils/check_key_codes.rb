# Lint: a row's code for several key columns is made by one part.
#
# A masked key determines nothing: with several key columns, one masked
# component leaves the row in no group.  CACategorical.from_keys
# (lib/carray/categorical.rb) makes the rows' codes for key columns of one
# length, and CAFrame#group_by, #is_duplicate and windows(on:, by:) use it.
# This check finds a code folded by hand --
#
#   code * n.elements + c      acc * cat.labels.size + cat.codes
#
# -- in lib/, and requires a note on the same line or within three lines
# above:
#
#   # keys: <why this place codes the rows itself>
#
# Run via `rake key_codes_check`, or `ruby utils/check_key_codes.rb`.

ROOT = File.expand_path("..", __dir__)

FOLD = /\*\s*[\w.\[\]]+(?:\.labels\.size|\.elements)\s*\+\s*\w/
NOTE = /keys:\s*\S/

offenders = []
Dir.chdir(ROOT) do
  Dir["lib/**/*.rb"].sort.each do |path|
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next if line =~ /\A\s*#/
      next unless line =~ FOLD
      next if lines[[i - 3, 0].max..i].any? { |l| l =~ NOTE }
      # the part itself
      next if path == "lib/carray/categorical.rb" &&
              lines[[i - 12, 0].max..i].join =~ /def self\.from_keys\b/
      offenders << [path, i + 1, line.strip]
    end
  end
end

if offenders.empty?
  puts "key_codes_check: every row code for several keys comes from the part"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "key_codes_check: #{offenders.size} place(s) fold key codes by hand."
puts "Use CACategorical.from_keys, or say why this place codes the rows itself:"
puts "  # keys: ..."
exit 1
