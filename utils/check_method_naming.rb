# Lint: an error names the method the user called, and that name comes from
# one place, ca_calling_method_name (ext/carray_utils.c), which walks the
# frames out to the user's code.  Reading the frame by hand
# (rb_frame_this_func and kin) gives the innermost C method instead -- the
# name a Ruby method of the library over a C one used to leak.  A read that
# picks something other than an error's name says so with `frame-name:`.
#
# Run via `rake method_naming_check`, or `ruby utils/check_method_naming.rb`.

ROOT = File.expand_path("..", __dir__)
ALLOWED = %w[carray_utils.c]
RULE = /\brb_frame_(this_func|callee|method_id)\s*\(/

files = Dir[File.join(ROOT, "ext", "*.{c,h}")].reject { |f| File.basename(f).start_with?("carray_kernels_") }
files << File.join(ROOT, "ext", "mkkernel.rb")

found = []
files.each do |path|
  next if ALLOWED.include?(File.basename(path))
  File.binread(path).each_line.with_index(1) do |l, n|
    next unless l =~ RULE
    next if l.include?("frame-name:") || l =~ %r{^\s*(/\*|\*)}
    found << "#{path.sub(ROOT + '/', '')}:#{n}: the frame read by hand: use ca_calling_method_name (another use says so with frame-name:)"
  end
end

if found.empty?
  puts "method_naming_check: ok"
else
  warn "method_naming_check: a method name read outside ca_calling_method_name:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
