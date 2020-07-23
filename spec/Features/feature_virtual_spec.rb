
require 'carray'
require "rspec-power_assert"

describe "TestCArrayVirtual " do

  example "clone" do
    a = CArray.int(3,3)
    a[1,1] = UNDEF
    b = a[1..2,1..2]
    is_asserted_by {  b == b.clone }
    is_asserted_by {  b == b.clone.to_ca }
    is_asserted_by {  b.mask == b.clone.mask }
    is_asserted_by {  b.object_id != b.clone.object_id }
    is_asserted_by {  b.mask.object_id != b.clone.mask.object_id }
  end

  example "attached?" do
    a = CArray.int(10,10)
    r = a[]
    is_asserted_by {  false == r.attached? }
    r.attach{
      is_asserted_by {  true == r.attached? }
    }
    is_asserted_by {  false == r.attached? }
    r.attach!{
      is_asserted_by {  true == r.attached? }
    }
  end

  example "root_array" do
    a = CArray.int(10,10).seq
    b = a[]
    c = b[0..5,nil]
    d = c[c > 50]
    e = d[d.address]
    is_asserted_by {  a.object_id == b.root_array.object_id }
    is_asserted_by {  a.object_id == c.root_array.object_id }
    is_asserted_by {  a.object_id == d.root_array.object_id }
    is_asserted_by {  a.object_id == e.root_array.object_id }
    is_asserted_by { [a.object_id,
                  b.object_id,
                  c.object_id,
                  d.object_id,
                  e.object_id] == e.ancestors.map{|x| x.object_id} }
  end

end
