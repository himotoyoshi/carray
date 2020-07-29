require 'carray'
require "rspec-power_assert"

describe "CAUnboundRepeat" do
  
  example "basic" do 
    a = CA_INT([1,2,3])
    b = a[:*,nil]
    c = a[nil,:*]
    
    is_asserted_by { b.class == CAUnboundRepeat }
    is_asserted_by { b.ndim == 2 }
    is_asserted_by { b.shape == [1,3] }
    

    is_asserted_by { c.class == CAUnboundRepeat }
    is_asserted_by { c.ndim == 2 }
    is_asserted_by { c.shape == [3,1] }

  end
  
  example "ref" do 
    a = CA_INT(0..2)[:*,nil]
    is_asserted_by { a[0] == 0 }
    is_asserted_by { a[1] == 1 }
    is_asserted_by { a[2] == 2 }
    is_asserted_by { a.bind(3,3) == CA_INT([[0,1,2],
                                            [0,1,2],
                                            [0,1,2]]) }
    is_asserted_by { a[0,0] == 0 }
    is_asserted_by { a[0,1] == 1 }
    is_asserted_by { a[0,2] == 2 }
    is_asserted_by { a.to_a == [[0,1,2]] }
  end
  
  example "bind" do 
  
    a = CA_INT([1,2,3])
    b = a[:*,nil]
    c = a[nil,:*]

    is_asserted_by { b.bind(3,3) == CA_INT([[1,2,3],
                                            [1,2,3],
                                            [1,2,3]]) }
    is_asserted_by { c.bind(3,3) == CA_INT([[1,1,1],
                                            [2,2,2],
                                            [3,3,3]]) }
  end

  example "bind_with" do 
  
    a = CA_INT([1,2,3])
    b = a[:*,nil]
    c = a[nil,:*]
    d = CArray.int(3,3)

    is_asserted_by { b.bind_with(d) == CA_INT([[1,2,3],
                                               [1,2,3],
                                               [1,2,3]]) }
    is_asserted_by { c.bind_with(d) == CA_INT([[1,1,1],
                                               [2,2,2],
                                               [3,3,3]]) }
  end
  
  example "arithmetic operation" do 

    a = CA_INT([1,2,3])
    b = a[:*,nil]
    c = a[nil,:*]
    
    is_asserted_by { b * c == CA_INT([[1,2,3],
                                      [2,4,6],
                                      [3,6,9]]) }

    
  end
  
  example "chain of unboundrepeat" do
    a = CA_INT([1,2,3])
    b = CArray.int(3,4)

    is_asserted_by { a[:*,nil].shape == [1,3] }
    is_asserted_by { a[:*,nil][:*,nil,nil].shape == [1,1,3] }

    expect {  a[:*,nil][nil,:*] }.to raise_error(ArgumentError)
    
    is_asserted_by { a[:*,nil][nil,nil,:*].shape == [1,3,1] }
    is_asserted_by { a[:*,nil][nil,:*,nil].shape == [1,1,3] }
    is_asserted_by { a[:*,nil][:*,nil,nil].shape == [1,1,3] }
  end
  
end