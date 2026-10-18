# Lint: an axis taken from Ruby is read by one part, ca_normalize_axis_arg
# (ext/carray_utils.c; CArray#normalize_axis and CArray.normalize_axis in
# Ruby).  It takes the argument as Ruby gave it: an Integer in [-ndim, ndim),
# negative counting from the end; any other Integer, however wide, raises
# ArgumentError naming the value; anything else raises TypeError.
#
# A copy reads the Integer into a C type first and compares afterwards.
# Narrowing first is how 2**32 + 1 came to be taken as axis 1, so the
# conversion (ca_axis_integer) and the message are not written outside
# carray_utils.c.  In Ruby, `axis < 0 ? axis + ndim : axis` and its kin are
# copies; a line that only gates a fast path (the slow path normalizes)
# says so with `# axis-check:`.
#
# The generated carray_kernels_*.c are not read; ext/mkkernel.rb is.
#
# Run via `rake axis_normalize_check`, or `ruby utils/check_axis_normalize.rb`.

ROOT = File.expand_path("..", __dir__)
ALLOWED = %w[carray_utils.c carray_internal.h carray.h]

RULES = [
  [/\bca_axis_integer\s*\(/,
   "ca_axis_integer: read the axis with ca_normalize_axis_arg"],
  [/out of range for ndim/,
   "an axis range message: ca_normalize_axis_arg raises it"],
  [/\brb_ca_normalize_axis_for_ndim\s*\((?![^;]*axis-check:)/m,
   "rb_ca_normalize_axis_for_ndim takes a C long, already narrowed: use ca_normalize_axis_arg (a long from a C caller says so with /* axis-check: */)"],
]

RUBY_RULES = [
  [/^(?!.*# axis-check:).*\b\w*axis\w*\s*<\s*0\s*\?\s*\w*axis\w*\s*\+\s*ndim/,
   "an axis normalized by hand: use normalize_axis"],
  [/^(?!.*# axis-check:).*\b\w*axis\w*\s*\+=\s*ndim\s+if\b/,
   "an axis normalized by hand: use normalize_axis"],
]

files = Dir[File.join(ROOT, "ext", "*.{c,h}")].reject { |f| File.basename(f).start_with?("carray_kernels_") }
files << File.join(ROOT, "ext", "mkkernel.rb")

found = []
files.each do |path|
  next if ALLOWED.include?(File.basename(path))
  text = File.binread(path)
  RULES.each do |re, hint|
    text.scan(re) do
      line = text[0, Regexp.last_match.begin(0)].count("\n") + 1
      found << "#{path.sub(ROOT + '/', '')}:#{line}: #{hint}"
    end
  end
end

Dir[File.join(ROOT, "lib", "**", "*.rb")].each do |path|
  File.binread(path).each_line.with_index(1) do |l, n|
    RUBY_RULES.each do |re, hint|
      found << "#{path.sub(ROOT + '/', '')}:#{n}: #{hint}" if l =~ re
    end
  end
end

if found.empty?
  puts "axis_normalize_check: ok"
else
  warn "axis_normalize_check: an axis read outside ca_normalize_axis_arg:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
