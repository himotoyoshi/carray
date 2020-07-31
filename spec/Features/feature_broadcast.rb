require 'carray'
require "rspec-power_assert"

describe "CArray.broadcast" do

  example "basic" do
    a = CArray.int(3,3).seq
    b = CArray.int(1,3).seq
    c = CArray.int(3,1).seq

    aa, bb, cc = CArray.broadcast(a,b,c)

    is_asserted_by { aa == a }
    is_asserted_by { bb == CA_INT([[0,1,2],
                                   [0,1,2],
                                   [0,1,2]]) }
    is_asserted_by { cc == CA_INT([[0,0,0],
                                   [1,1,1],
                                   [2,2,2]]) }

  end

  example "with unboud repeat" do
    a = CArray.int(3,3).seq
    b = CArray.int(3).seq[:*,nil]
    c = CArray.int(3).seq[nil,:*]

    aa, bb, cc = CArray.broadcast(a,b,c)

    is_asserted_by { aa == a }
    is_asserted_by { bb == CA_INT([[0,1,2],
                                   [0,1,2],
                                   [0,1,2]]) }
    is_asserted_by { cc == CA_INT([[0,0,0],
                                   [1,1,1],
                                   [2,2,2]]) }

  end

  example "with cscalar" do 
    a = CArray.int(3,3).seq
    b = CA_INT(3)            ### CScalar

    aa, bb = CArray.broadcast(a,b)
    is_asserted_by { aa == a }
    is_asserted_by { bb.class == CScalar }
    is_asserted_by { bb == b }
    
  end
  
  example "can't broadcast" do 
    a = CArray.int(3,3).seq
    b = CArray.int(3,2).seq
    c = CArray.int(2,2).seq

    expect {
      aa, bb, cc = CArray.broadcast(a,b,c)
    }.to raise_error(RuntimeError)
  end
  
  example "1 elements array" do 
    a = CArray.int(1,1).seq
    b = CArray.int(1,1).seq
    c = CArray.int(1,1).seq

    aa, bb, cc = CArray.broadcast(a,b,c)

    is_asserted_by { aa == a }
    is_asserted_by { bb == b }
    is_asserted_by { cc == c } 
  end
  
  example "include numeric" do 
    a = CArray.int(1,3).seq
    b = 1.0
    c = CArray.int(3,1).seq
    
    aa, bb, cc = CArray.broadcast(a,b,c)
   
    is_asserted_by { aa == CA_INT([[0,1,2],
                                   [0,1,2],
                                   [0,1,2]]) }
    is_asserted_by { bb == 1.0 }                                   
    is_asserted_by { cc == CA_INT([[0,0,0],
                                   [1,1,1],
                                   [2,2,2]]) }

  end

  example "all numeric" do 
    a = 1.0
    b = 2.0
    c = 3.0
    aa, bb, cc = CArray.broadcast(a,b,c)
    is_asserted_by { aa == a }
    is_asserted_by { bb == b }                                   
    is_asserted_by { cc == c }
  end
  
  example "extension of dimension" do
    a = CA_INT([[1,2,3],[4,5,6]])
    
    is_asserted_by { a.broadcast_to(1,2,1,3) == CA_INT([[[[ 1, 2, 3 ]],
                                                         [[ 4, 5, 6 ]]]]) }

    is_asserted_by { a.reshape(2,1,3).broadcast_to(1,2,1,3) == CA_INT([[[[ 1, 2, 3 ]],
                                                                        [[ 4, 5, 6 ]]]]) }
      
    is_asserted_by { a.reshape(1,2,3).broadcast_to(1,2,1,3) == CA_INT([[[[ 1, 2, 3 ]],
                                                                        [[ 4, 5, 6 ]]]]) }
      
      
  end
  
  
end