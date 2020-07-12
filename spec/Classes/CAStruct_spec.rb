
require 'carray'
require "rspec-power_assert"

describe "TestCArrayStruct " do

  example "struct" do
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    a = CArray.new(st, [3])
    b = CArray.new(:fixlen, [3], :bytes=>3)
    is_asserted_by {  true == a.has_data_class? }
    is_asserted_by {  st == a.data_class }
    is_asserted_by {  true == a.to_ca.has_data_class? }
    is_asserted_by {  st == a.to_ca.data_class }
    is_asserted_by {  true == a.template.has_data_class? }
    is_asserted_by {  st == a.template.data_class }
    is_asserted_by {  true == a[].has_data_class? }
    is_asserted_by {  st == a[].data_class }
    is_asserted_by {  false == b.has_data_class? }
  end

  example "struct_to_type" do
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    is_asserted_by {  5 == st.size }
    a = CArray.new(:fixlen, [3], :bytes=>5)
    b = a.to_type(st)
    is_asserted_by {  false == a.has_data_class? }
    is_asserted_by {  true == b.has_data_class? }
    is_asserted_by {  st == b.data_class }
  end

  example "struct_refer" do
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    a = CArray.new(:fixlen, [3], :bytes=>5)
    b = a.refer(st, a.dim)
    is_asserted_by {  false == a.has_data_class? }
    is_asserted_by {  true == b.has_data_class? }
    is_asserted_by {  st == b.data_class }
  end

  example "swap_bytes" do
    st = CA.struct(:pack=>1) {
      uint16 :mem_i
      char_p :mem_f, :bytes => 3
      struct(:mem_s) {
        uint16 :mem_i
        char_p :mem_f, :bytes => 3
      }
    }
    a = CArray.new(st, [3])
    is_asserted_by {  true == a.has_data_class? }
    is_asserted_by {  st == a.data_class }
    is_asserted_by {  CAField == a.field(:mem_i).class }
    is_asserted_by {  CAField == a.field(:mem_s).class }
    is_asserted_by {  a.field("mem_i") == a["mem_i"] }
    a["mem_i"] = 255
    a["mem_f"] = "abc"
    a["mem_s"]["mem_i"] = (255 << 8)
    a["mem_s"]["mem_f"] = "abc"
    b = CArray.new(st, [3])
    b["mem_i"] = (255 << 8)
    b["mem_f"] = "cba"
    b["mem_s"]["mem_i"] = 255
    b["mem_s"]["mem_f"] = "cba"
    is_asserted_by {  b == a.swap_bytes }
    is_asserted_by {  a == b.swap_bytes }
    a.swap_bytes!
    is_asserted_by {  b == a }
  end

end
