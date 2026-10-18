# Lint: whether a kernel can raise on a cell is decided by one part.
#
# A masked cell must not be computed by a kernel that can raise on it (an
# object cell, an integer division or reciprocal by zero, an integer power
# of zero to a negative exponent).  ca_op_raises_on_cell (ext/
# carray_operator.c) decides which those are; the eager operators, the
# lazy views and the plans an evaluator is handed ask it alone.  This check
# finds a place that decides it otherwise --
#
#   a C function of an operator kind (ca_monop_* ... ca_bincmp_*, rb_ca_*)
#     named *_trapping or *_may_raise whose body does not call
#     ca_op_raises_on_cell
#   a lazy view taking the mask to skip (slab_mask = ca_lazy_req_mask(...))
#     under a condition that does not call it
#
# -- and requires a note on the line or within six lines above:
#
#   /* raises: <why this place decides it itself> */
#
# Run via `rake cell_raise_check`, or `ruby utils/check_cell_raise.rb`.

ROOT = File.expand_path("..", __dir__)

FUNC_HEAD = /\A([a-z_][a-z0-9_]*)\s*\(/
NAMED     = /\A(?:rb_)?ca_(?:monop|binop|triop|moncmp|bincmp)_\w*(?:trapping|may_raise)\z/
PART      = /\bca_op_raises_on_cell\s*\(/
SKIP_MASK = /\bslab_mask\s*=\s*ca_lazy_req_mask\s*\(/
NOTE      = /raises:\s*\S/

offenders = []
Dir.chdir(ROOT) do
  Dir["ext/*.c"].sort.each do |path|
    next if path =~ %r{/carray_kernels_}
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      name = line[FUNC_HEAD, 1]
      if name && name =~ NAMED && lines[i + 1].to_s.start_with?("{")
        j = i + 1
        j += 1 until j >= lines.size || lines[j].start_with?("}")
        body = lines[i..j].join
        unless body =~ PART || lines[[i - 6, 0].max..i].any? { |l| l =~ NOTE }
          offenders << [path, i + 1, "#{name} does not ask ca_op_raises_on_cell"]
        end
      end
      if line =~ SKIP_MASK
        above = lines[[i - 6, 0].max..i]
        unless above.any? { |l| l =~ PART || l =~ NOTE }
          offenders << [path, i + 1, line.strip]
        end
      end
    end
  end
end

if offenders.empty?
  puts "cell_raise_check: every masked-cell skip asks ca_op_raises_on_cell"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "cell_raise_check: #{offenders.size} place(s) decide by hand whether a kernel can raise."
puts "Ask ca_op_raises_on_cell, or say why:  /* raises: ... */"
exit 1
