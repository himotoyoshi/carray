# Lint: the order of NaN is decided by the parts, not written by hand.
#
# Sort and every order statistic (partition, median, percentile, rank,
# nlargest, the search family) put a NaN after every number, and NaN ties
# NaN.  The rule lives in parts:
#
#   CA_FLOAT_ORDER_CMP(a, b)   three-way float order (ext/carray_internal.h)
#   ca_obj_order_cmp(a, b)     the same for object cells
#   ca_partition_nan_*         NaN of a float buffer to its tail
#                              (ext/carray_sort_kernel.c, ca_sort_kernels.h)
#
#   CArray.object_order_cmp    the same for two Ruby values (lib/carray/basics.rb)
#
# and a Ruby method orders an array through the C sort (sort_index).  This
# check finds the shapes a hand-written copy takes --
#
#   C     isnan(a) && !isnan(b)        nan_a / nan_b flags
#         isnan(v) ) { hi = ...          (a binary search skipping NaN)
#         x[i] != x[i]                  (a NaN test on a buffer cell)
#   Ruby  x.nan? beside a sort, sort_by or <=>
#
# -- in ext/*.c, ext/*.h, the C templates in ext/mkkernel.rb and lib/, and
# requires a note on the same line or the line above:
#
#   /* nan-order: <why this place decides it itself> */   (C)
#   # nan-order: <why this place decides it itself>       (Ruby)
#
# The parts themselves and the generated carray_kernels_*.c are not read.
#
# Run via `rake nan_order_check`, or `ruby utils/check_nan_order.rb`.

ROOT = File.expand_path("..", __dir__)

C_SHAPES = [
  /isnan\s*\([^)]*\)\s*\)?\s*&&\s*\(?\s*!\s*isnan/,
  /\bnan_[ab]\b/,
  /(?:CA_OBJ_ISNAN|isnan)\s*\([^{]*\)\s*\)\s*\{\s*hi\s*=/,
  /(?<![\w>.])(\w+)\[(\w+)\]\s*!=\s*\1\[\2\]/,
]
RUBY_SORT = /\bsort(_by)?\b|<=>/
NOTE      = /nan-order:\s*\S/

# The parts: the files and the lines that are the rule.
PART_FILES = %w[ext/carray_sort_kernel.c ext/ca_sort_kernels.h]
PART_LINES = /CA_FLOAT_ORDER_CMP|ca_obj_order_cmp\s*\(VALUE/

def noted? (lines, i)
  lines[i] =~ NOTE || (i > 0 && lines[i - 1] =~ NOTE)
end

offenders = []
Dir.chdir(ROOT) do
  files = Dir["ext/*.c"] + Dir["ext/*.h"] + ["ext/mkkernel.rb"]
  files.sort.each do |path|
    next if path =~ %r{/carray_kernels_} || PART_FILES.include?(path)
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next unless C_SHAPES.any? { |re| line =~ re }
      next if noted?(lines, i)
      # the definition of the part, and the comment that names it
      next if path == "ext/carray_internal.h" &&
              (lines[[i - 12, 0].max..i].join =~ PART_LINES)
      offenders << [path, i + 1, line.strip]
    end
  end
  Dir["lib/**/*.rb"].sort.each do |path|
    lines = File.readlines(path, encoding: "UTF-8")
    lines.each_with_index do |line, i|
      next unless line =~ /\.nan\?/
      window = lines[[i - 8, 0].max..[i + 8, lines.size - 1].min].join
      next unless window =~ RUBY_SORT
      next if noted?(lines, i)
      # the definition of the Ruby part
      next if lines[[i - 6, 0].max..i].join =~ /def self\.object_order_cmp\b/
      offenders << [path, i + 1, line.strip]
    end
  end
end

if offenders.empty?
  puts "nan_order_check: every NaN order goes through the parts or says why"
  exit 0
end

offenders.each { |path, line, text| puts "#{path}:#{line}: #{text}" }
puts
puts "nan_order_check: #{offenders.size} place(s) order NaN by hand."
puts "Use CA_FLOAT_ORDER_CMP / ca_obj_order_cmp / ca_partition_nan_* (C) or"
puts "sort_index (Ruby), or say why this place decides it itself:"
puts "  /* nan-order: ... */   # nan-order: ..."
exit 1
