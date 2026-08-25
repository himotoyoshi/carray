# c-extensions/per_element/example.rb
#
# CA_FOR_EACH_ELEMENT macro family — 5 forms.
#
# Build before running:
#   ruby extconf.rb && make
#
# Then run:
#   ruby example.rb

$LOAD_PATH.unshift(__dir__)
require "carray"
require "per_element"

puts "=== (1) CA_FOR_EACH_ELEMENT — read-only, no mask ==="
a = CArray.float64(5) { |i| i.to_f + 1.0 }
puts "input:  #{a.to_a.inspect}"
puts "sum:    #{CArray.demo_sum_f64(a)}    (= demo_sum_f64)"
puts

puts "=== (2) CA_FOR_EACH_ELEMENT_MASKED — read-only with mask ==="
b = CArray.float64(5) { |i| i.to_f }
b[2] = UNDEF
puts "input:  #{b.to_a.inspect}    (index 2 masked)"
puts "count:  #{CArray.demo_count_unmasked_f64(b)} unmasked cells"
puts

puts "=== (3) CA_FOR_EACH_ELEMENT_INOUT — map in→out, no mask ==="
out = CArray.float64(5)
CArray.demo_square_f64(a, out)
puts "input:  #{a.to_a.inspect}"
puts "x*x:    #{out.to_a.inspect}"
puts

puts "=== (4) CA_FOR_EACH_ELEMENT_INOUT_MASKED — map with mask propagation ==="
c = CArray.float64(6) { |i| [-1.0, 4.0, 9.0, -16.0, 25.0, 0.0][i] }
c[5] = UNDEF
out2 = CArray.float64(6)
CArray.demo_safe_sqrt_f64(c, out2)
puts "input:  #{c.to_a.inspect}    (index 5 masked, negatives at 0,3)"
puts "sqrt:   #{out2.to_a.inspect} (mask propagated for negatives + input mask)"
puts

puts "=== (5) CA_FOR_EACH_ELEMENT_OUT — write-only fill ==="
out3 = CArray.float64(5)
CArray.demo_iota_f64(out3, 10.0, 0.5)
puts "fill:   offset=10.0 step=0.5 → #{out3.to_a.inspect}"
