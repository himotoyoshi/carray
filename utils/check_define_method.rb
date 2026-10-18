# Lint: an error names the method the user called, found from the frames
# (ca_calling_method_name, ext/carray_utils.c).  A method made by
# define_method carries no name in its frame -- its body is a block -- so an
# error raised inside it names something within it instead.  A method of the
# library is a `def`; a family of them is made by
# CArray.define_named_methods (lib/carray/runtime.rb), which writes one
# `def` per name that hands its name to a shared private method.
#
# A define_method that has a reason to stay says so with `# define_method:`
# on the line or the line above (a stub that names itself in its message).
# The rest are counted per file, and a file may not gain one: this is a
# ratchet, lowered as the families move.
#
# Run via `rake define_method_check`, or `ruby utils/check_define_method.rb`.

ROOT = File.expand_path("..", __dir__)

COUNTS = {
  "carray/autoload_method_extension.rb" => 1,   # the stub; a block of the library, passed by the walk
  "carray/const_string.rb"   => 1,

  "carray/frame/windows.rb"  => 1,
  "carray/record_order.rb"   => 2,
  "carray/struct.rb"         => 1,
  "carray/struct_builder.rb" => 2,
}.freeze

found = Hash.new(0)
Dir[File.join(ROOT, "lib", "**", "*.rb")].sort.each do |path|
  lines = File.read(path, encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ /\bdefine_method\b/ && l !~ /^\s*#/
    next if l =~ /#\s*define_method:/ || (i > 0 && lines[i - 1] =~ /#\s*define_method:/)
    found[path.sub(File.join(ROOT, "lib") + "/", "")] += 1
  end
end

over = found.select { |f, n| n > COUNTS.fetch(f, 0) }
under = COUNTS.select { |f, n| found[f] < n }
if over.empty? && under.empty?
  puts "define_method_check: ok"
else
  over.each do |f, n|
    warn "define_method_check: lib/#{f} has #{n} define_method (allowed #{COUNTS.fetch(f, 0)}): " \
         "make the methods with CArray.define_named_methods, or say why with # define_method:"
  end
  under.each do |f, n|
    warn "define_method_check: lib/#{f} has #{found[f]} define_method, fewer than #{n}: lower its count"
  end
  exit 1
end
