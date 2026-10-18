# Lint: a write into a read-only array that is not frozen is refused by one
# part, ca_refuse_read_only (ext/carray_test.c): RuntimeError "<method>: can
# not modify read-only array".  The entry points reach it through
# rb_ca_modify; the transfers and fills below them call it as the last line.
# A frozen array is Ruby's FrozenError, from rb_check_frozen.
#
# The guards had grown their own wording -- "can not store data to ...",
# "can not fill data to ...", "CABinOp is read-only (xfer_index PUT)" -- and
# none named the method.  A raise that says "read-only" outside the part is
# a copy; one that says something else (which array, the mask of a lazy
# node) carries `read-only-check:` on the line or the line above.
#
# Run via `rake read_only_refusal_check`, or `ruby utils/check_read_only_refusal.rb`.

ROOT = File.expand_path("..", __dir__)
ALLOWED = %w[carray_test.c]

found = []
Dir[File.join(ROOT, "ext", "*.c")].sort.each do |path|
  base = File.basename(path)
  next if base.start_with?("carray_kernels_") || ALLOWED.include?(base)
  lines = File.read(path, encoding: "UTF-8").lines
  lines.each_with_index do |l, i|
    next unless l =~ /rb_raise\s*\(.*read[- ]only/i
    next if l.include?("read-only-check:") || (i > 0 && lines[i - 1].include?("read-only-check:"))
    found << "ext/#{base}:#{i + 1}: a read-only refusal of its own: call ca_refuse_read_only()"
  end
end

if found.empty?
  puts "read_only_refusal_check: ok"
else
  warn "read_only_refusal_check: a write into a read-only array refused outside the part:"
  found.each { |l| warn "  #{l}" }
  exit 1
end
