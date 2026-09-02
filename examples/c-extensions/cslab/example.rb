# c-extensions/cslab/example.rb
#
# ca_call_cslab_*_r — the chunked counterpart of the cfunc family.
#
# Build before running:
#   ruby extconf.rb && make
#
# Then run:
#   ruby example.rb

$LOAD_PATH.unshift(__dir__)
require "carray"
require "cslab"
require "benchmark"

puts "=== ca_call_cslab_3_r — out = a + b * scale ==="
a = CArray.float64(5) { |i| (i + 1).to_f }
b = CArray.float64(5) { |i| (i + 1).to_f * 0.5 }
out = CArray.float64(5)
result, chunks, chunk_n_max, = CArray.demo_cslab_3_r(out, a, b, 2.0)
puts "a       = #{a.to_a.inspect}"
puts "b       = #{b.to_a.inspect}"
puts "out     = #{result.to_a.inspect}"
puts "matches   #{result.to_a == (a + b * 2.0).to_a}"
puts "chunks  = #{chunks} (largest #{chunk_n_max} cells)"
puts

puts "=== a masked INPUT ==="
# The engine ORs the INPUT masks into m0 and hands each chunk its slice; the
# callback skips those cells, and the OUTPUT mask is propagated at release.
# A slab has no way to leave a hole, so unlike the per-cell form the skip is
# the author's to write.
# (a fresh array: CArray#to_ca returns self for an entity, so masking a
# "copy" of `a` taken that way would mask `a` itself)
am = CArray.float64(5) { |i| (i + 1).to_f }
am[2] = UNDEF
masked_out = CArray.float64(5)
CArray.demo_cslab_3_r(masked_out, am, b, 2.0)
puts "input   = #{am.to_a.inspect}"
puts "out     = #{masked_out.to_a.inspect}"
puts "mask    = #{masked_out.is_masked.to_a.inspect}"
puts

puts "=== a view as OUTPUT and as INPUT ==="
grid = CArray.float64(3, 5).seq
src  = CArray.float64(3, 5).seq(100.0)
CArray.demo_cslab_3_r(grid[nil, 2], src[nil, 2], b[0..2], 2.0)
puts grid.to_a.inspect
puts

n = 4_000_000
big_a = CArray.float64(n).seq
big_b = CArray.float64(n).seq(0.5, 0.5)
big_out = CArray.float64(n)

puts "=== the chunk walk, n = #{n} ==="
_, chunks, chunk_n_max, = CArray.demo_cslab_3_r(big_out, big_a, big_b, 2.0)
puts "#{chunks} chunks, largest #{chunk_n_max} cells " \
     "(= #{chunk_n_max * 8 / 1024} KB per gathered operand, whatever n is)"
puts

puts "=== per-cell against per-chunk ==="
# An entity INPUT is walked in place by both families, so this isolates the
# call shape: one indirect call per cell against one per chunk.
def timed (n)
  Benchmark.realtime { 5.times { yield } } / 5
end
slab  = timed(n) { CArray.demo_cslab_3_r(big_out, big_a, big_b, 2.0) }
cfunc = timed(n) { CArray.demo_cfunc_3_r(big_out, big_a, big_b, 2.0) }
plain = timed(n) { big_a + big_b * 2.0 }
puts "  ca_call_cslab_3_r  %6.2f ms  %5.2f ns/element" % [slab * 1e3, slab / n * 1e9]
puts "  ca_call_cfunc_3_r  %6.2f ms  %5.2f ns/element" % [cfunc * 1e3, cfunc / n * 1e9]
puts "  a + b * 2.0        %6.2f ms  %5.2f ns/element" % [plain * 1e3, plain / n * 1e9]
puts

puts "=== what the INPUT is decides whether it is gathered ==="
# `gathered` reads the callback's own eyes: operand 1's base does not move
# between chunks exactly when the chunk was re-gathered into arena scratch.
# Where it is false the operand was walked in place and no scratch existed.
{
  "entity"          => big_a,
  "src[nil]"        => big_a[nil],
  "reverse"         => big_a.reverse,
  "gather src[idx]" => big_a[CArray.int32(n).seq.reverse],
}.each do |label, input|
  _, _, _, gathered = CArray.demo_cslab_3_r(big_out, input, big_b, 2.0)
  correct = big_out.to_a == (input.to_ca + big_b * 2.0).to_a
  slab  = timed(n) { CArray.demo_cslab_3_r(big_out, input, big_b, 2.0) }
  cfunc = timed(n) { CArray.demo_cfunc_3_r(big_out, input, big_b, 2.0) }
  puts "  %-16s gathered=%-5s correct=%-5s  cslab %6.2f ms   cfunc %6.2f ms" %
       [label, gathered.inspect, correct, slab * 1e3, cfunc * 1e3]
end
puts

puts "=== ca_call_cslab_1_1_r — the typed dispatcher ==="
# The caller declares the data types its callback works in; the dispatcher
# wraps the input readonly to that type and allocates the output.  No out
# array to pass, no dtype to match by hand.
y, single_chunk, = CArray.demo_cslab_1_1_r(CArray.float64(5).seq(1.0), 10.0)
puts "  float64 in : #{y.to_a.inspect}  (#{y.data_type_name}, #{single_chunk} chunk)"
y, = CArray.demo_cslab_1_1_r(CArray.int32(5).seq(1), 10.0)
puts "  int32 in   : #{y.to_a.inspect}  (#{y.data_type_name}) ← coerced for you"
y, = CArray.demo_cslab_1_1_r(CScalar.float64.tap { |s| s[0] = 3.0 }, 10.0)
puts "  scalar in  : #{y.inspect} (#{y.class}) ← rank-0 comes back as a number"
puts

puts "=== why the typed layer is where chunking pays ==="
# The coercion is a lazy readonly cast view, and a cast view is never
# attach-alias -- so it is precisely the operand kind the whole-buffer path
# copies whole.  Declaring CA_DOUBLE over an int32 array is the ordinary way
# to use this layer, and it is the case chunking was built for.
[["float64 (no coercion)", big_a],
 ["int32   (coerced)    ", CArray.int32(n).seq]].each do |label, x|
  _, _, gathered = CArray.demo_cslab_1_1_r(x, 2.0)
  slab  = timed(n) { CArray.demo_cslab_1_1_r(x, 2.0) }
  cfunc = timed(n) { CArray.demo_cfunc_1_1_r(x, 2.0) }
  puts "  %s gathered=%-5s  cslab %6.2f ms   cfunc %6.2f ms" %
       [label, gathered.inspect, slab * 1e3, cfunc * 1e3]
end
