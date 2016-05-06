$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayStruct < Test::Unit::TestCase

  def test_struct
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    a = CArray.new(st, [3])
    b = CArray.new(:fixlen, [3], :bytes=>3)
    assert_equal(true, a.has_data_class?)
    assert_equal(st, a.data_class)
    assert_equal(true, a.to_ca.has_data_class?)
    assert_equal(st, a.to_ca.data_class)
    assert_equal(true, a.template.has_data_class?)
    assert_equal(st, a.template.data_class)
    assert_equal(true, a[].has_data_class?)
    assert_equal(st, a[].data_class)
    assert_equal(false, b.has_data_class?)          
  end

  def test_struct_to_type
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    assert_equal(5, st.size)
    a = CArray.new(:fixlen, [3], :bytes=>5)
    b = a.to_type(st)
    assert_equal(false, a.has_data_class?)
    assert_equal(true, b.has_data_class?)   
    assert_equal(st, b.data_class)
  end

  def test_struct_refer
    st = CA.struct(:pack=>1) { uint16 :mem_i; char_p :mem_f, :bytes => 3 }
    a = CArray.new(:fixlen, [3], :bytes=>5)
    b = a.refer(st, a.dim)
    assert_equal(false, a.has_data_class?)
    assert_equal(true, b.has_data_class?)   
    assert_equal(st, b.data_class)    
  end

  def test_swap_bytes
    st = CA.struct(:pack=>1) {
      uint16 :mem_i
      char_p :mem_f, :bytes => 3
      struct(:mem_s) {
        uint16 :mem_i
        char_p :mem_f, :bytes => 3
      }
    }
    a = CArray.new(st, [3])
    assert_equal(true, a.has_data_class?)
    assert_equal(st, a.data_class)
    assert_equal(CAField, a.field(:mem_i).class)
    assert_equal(CAField, a.field(:mem_s).class)
    assert_equal(a.field("mem_i"), a["mem_i"])
    a["mem_i"] = 255
    a["mem_f"] = "abc"
    a["mem_s"]["mem_i"] = (255 << 8)
    a["mem_s"]["mem_f"] = "abc"
    b = CArray.new(st, [3])
    b["mem_i"] = (255 << 8)
    b["mem_f"] = "cba"
    b["mem_s"]["mem_i"] = 255
    b["mem_s"]["mem_f"] = "cba"
    assert_equal(b, a.swap_bytes)
    assert_equal(a, b.swap_bytes)
    a.swap_bytes!
    assert_equal(b, a)
  end

end
