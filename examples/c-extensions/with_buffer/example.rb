# c-extensions/with_buffer/example.rb
#
# rb_ca_call_with_buffer: the whole array as one contig buffer.
#
# Build before running:
#   ruby extconf.rb && make
#
# Then run:
#   ruby example.rb

$LOAD_PATH.unshift(__dir__)
require "carray"
require "with_buffer"

a = CArray.float64(5) { |i| (i + 1).to_f }

puts "=== (1) read-only ==="
puts "input:  #{a.to_a.inspect}"
puts "sum:    #{CArray.demo_with_buffer_sum_f64(a)}"
puts

puts "=== (2) writable, in place ==="
b = a.copy
CArray.demo_with_buffer_scale_f64(b, 3.0)
puts "before: #{a.to_a.inspect}"
puts "after × 3.0: #{b.to_a.inspect}"
puts

puts "=== (3) a view: materialised, then synced back ==="
big = CArray.float64(8) { |i| (i + 1).to_f }
CArray.demo_with_buffer_scale_f64(big[2..4], 10.0)
puts "big after scaling big[2..4]: #{big.to_a.inspect}"
puts

puts "=== (4) the body raises: the view is still synced and detached ==="
c = a.copy
begin
  CArray.demo_with_buffer_raise(c, 2, true)
rescue RuntimeError => e
  puts "raised: #{e.message}"
  puts "array after raise: #{c.to_a.inspect}"
  puts "  (cells up to index 2 were written before the raise)"
end
