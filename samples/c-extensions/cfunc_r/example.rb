# c-extensions/cfunc_r/example.rb
#
# ca_call_cfunc_*_r — reentrant cfunc family with userdata threading.
#
# Build before running:
#   ruby extconf.rb && make
#
# Then run:
#   ruby example.rb

$LOAD_PATH.unshift(__dir__)
require "carray"
require "cfunc_r"

puts "=== ca_call_cfunc_1_1_r — single-input scale ==="
a = CArray.float64(5) { |i| (i + 1).to_f }
puts "input:  #{a.to_a.inspect}"
y = CArray.demo_cfunc_r_1_1(a, 10.0)
puts "scale=10 → #{y.to_a.inspect}"
puts

puts "=== ca_call_cfunc_2_2_r — dual-input scale + mutable userdata counter ==="
b = CArray.float64(5) { |i| (i + 1).to_f * 0.5 }
puts "inputs: a=#{a.to_a.inspect}"
puts "        b=#{b.to_a.inspect}"
(out_y, out_x), hits = CArray.demo_cfunc_r_2_2(a, b, 2.0, 3.5)
puts "scale=2, threshold=3.5:"
puts "  y (= a*2) = #{out_y.to_a.inspect}"
puts "  x (= b*2) = #{out_x.to_a.inspect}"
puts "  hits (a[i] > 3.5)  = #{hits}    ← userdata mutated across cells"
