require "carray"
require 'rspec-power_assert'

describe "CArray#project" do

  example "basic" do
    a = CA_DOUBLE([[11,22,33],
                   [44,55,66],
                   [77,88,99]])

    # CA_SIZE
    idxsz = CA_SIZE([[1,2,3],
                     [4,5,6],
                     [7,8,0]])

                     
    is_asserted_by { a.project(idxsz).class == CArray }          ### entity array
    is_asserted_by { a.project(idxsz).data_type == a.data_type } ### data_type is inherited from base array
    is_asserted_by { a.project(idxsz).shape == idxsz.shape }     ### shape is inherieted from index array

    is_asserted_by { 
      a.project(idxsz) == CA_DOUBLE([[22,33,44],
                                     [55,66,77],
                                     [88,99,11]])
    }

  end

  example "permits integer array for index arugument" do

    a = CA_DOUBLE([[11,22,33],
                   [44,55,66],
                   [77,88,99]])


    is_asserted_by { 
      # CA_INT8
      idx8 = CA_INT8([[1,2,3],
                      [4,5,6],
                      [7,8,0]])

      a.project(idx8) == CA_DOUBLE([[22,33,44],
                                    [55,66,77],
                                    [88,99,11]])
    }

    is_asserted_by { 
      # CA_INT32
      idx32 = CA_INT32([[1,2,3],
                        [4,5,6],
                        [7,8,0]])

      a.project(idx32) == CA_DOUBLE([[22,33,44],
                                     [55,66,77],
                                     [88,99,11]])
    }

    is_asserted_by { 
      # CA_INT64
      idx64 = CA_INT64([[1,2,3],
                        [4,5,6],
                        [7,8,0]])

      a.project(idx64) == CA_DOUBLE([[22,33,44],
                                     [55,66,77],
                                     [88,99,11]])
    }
    
  end

  example "returns array which has the shape of index argument" do
    # 3x4
    a = CA_DOUBLE([[0, 1, 2, 3],
                   [4, 5, 6, 7],
                                               [8, 9, 10,11]]) + 100

    is_asserted_by { 
      # 1x12
      idx = CA_INT64([0,1,2,3,4,5,6,7,8,9,10,11])

      a.project(idx).shape == idx.shape
    }

    is_asserted_by { 
      # 2x6
      idx = CA_INT64([[0,1,2,3,4,5],
                      [6,7,8,9,10,11]])

      a.project(idx).shape == idx.shape
    }

    is_asserted_by { 
      # 4x3
      idx = CA_INT64([[0,1,2],
                      [3,4,5],
                      [6,7,8],
                      [9,10,11]])

      a.project(idx).shape == idx.shape
    }

    is_asserted_by { 
      # 2x3
      idx = CA_INT64([[0,1,2],
                      [3,4,5]])

      a.project(idx).shape == idx.shape
    }

  end
  
  example "masked array" do

    # masked base array

    _ = UNDEF

    a = CA_DOUBLE([[11,_ ,33],
                   [44,55,66],
                   [77,88,99]])

    is_asserted_by { 
      # idx without mask
      idx = CA_INT64([[1,2,3],
                      [4,5,6],
                      [7,8,0]])

      a.project(idx) == CA_DOUBLE([[_ ,33,44],
                                   [55,66,77],
                                   [88,99,11]])
    }

    is_asserted_by { 
      # index with mask
      idx = CA_SIZE([[1,2,3],
                     [4,_,6],
                     [7,8,0]])

      a.project(idx) == CA_DOUBLE([[_ ,33,44],
                                   [55,_ ,77],
                                   [88,99,11]])
    }

    # Related: Comparing the behavior of CArray#[idx] with idx has mask
    #

    is_asserted_by { 
      # For CArray#[idx], nothing is raised even if base array has masked element.

      # idx without mask
      idx = CA_SIZE([[1,2,3],
                     [4,5,6],
                     [7,8,0]])


      a[idx] == CA_DOUBLE([[_ ,33,44],
                           [55,66,77],
                           [88,99,11]])
    }

    # For CArray#[idx], ArgumentError is raised if idx has masked element.
    expect { 
      # idx with mask
      idx = CA_SIZE([[1,2,3],
                     [4,_,6],
                     [7,8,0]])
      a[idx] 
    }.to raise_error(ArgumentError)

  end

  example "edge cases" do
    _ = UNDEF
    a = CA_DOUBLE([[11,22,33],
                   [44,55,66],
                   [77,88,99]])
    is_asserted_by { a.project(CA_SIZE([])) == CA_DOUBLE([]) }
    is_asserted_by { a.project(CA_SIZE([9])) == CA_DOUBLE([_]) }
    is_asserted_by { a.project(CA_SIZE([-1])) == CA_DOUBLE([_]) }
    is_asserted_by { a.project(CA_SIZE([-1]), 999) == CA_DOUBLE([999]) }
    is_asserted_by { a.project(CA_SIZE([9]), 999) == CA_DOUBLE([999]) }
    is_asserted_by { a.project(CA_SIZE([-1]), -999) == CA_DOUBLE([-999]) }
    is_asserted_by { a.project(CA_SIZE([9]), -999, 999) == CA_DOUBLE([999]) }
    
  end
  

end