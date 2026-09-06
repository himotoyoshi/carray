# c-extensions/with_buffer/example.rb
#
# CA_WITH_BUFFER / CA_WITH_BUFFER_WRITABLE / rb_ca_call_with_buffer.
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

puts "=== (1) CA_WITH_BUFFER — scoped read-only view ==="
puts "input:  #{a.to_a.inspect}"
puts "sum:    #{CArray.demo_with_buffer_sum_f64(a)}"
puts

puts "=== (2) CA_WITH_BUFFER_WRITABLE — scoped writable view (in-place) ==="
b = a.copy
CArray.demo_with_buffer_scale_f64(b, 3.0)
puts "before: #{a.to_a.inspect}"
puts "after × 3.0: #{b.to_a.inspect}"
puts

puts "=== (3) Break-from-body is safe (detach still runs) ==="
puts "partial sum (first 3 cells): #{CArray.demo_with_buffer_break_after_k(a, 3)}"
puts "  (verify: #{a.to_a.first(3).sum})"
puts

puts "=== (4) rb_ca_call_with_buffer — function form with rb_ensure ==="
puts "sum via callback: #{CArray.demo_call_with_buffer_sum_f64(a)}"
puts

puts "=== (5) raise mid-body: rb_ensure runs sync + detach cleanly ==="
c = a.copy
begin
  CArray.demo_call_with_buffer_raise(c, 2, true)
rescue RuntimeError => e
  puts "raised: #{e.message}"
  puts "view (after raise, syncs apply): #{c.to_a.inspect}"
  puts "  (cells before raise index 2 were written; raise still ran cleanly)"
end
