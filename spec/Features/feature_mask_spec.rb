require 'carray'
require 'rspec-power_assert'

describe "Feature: Masking" do

  example "basic_features" do

    # ---
    a = CArray.int32(3,3).seq!
    is_asserted_by { false == a.has_mask? }          ### mask array is not created
    is_asserted_by { CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]) == a.value }
    is_asserted_by { 0 == a.mask }                    ### mask array is not created
    is_asserted_by { CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]) == a.is_masked }
    is_asserted_by { CA_BOOLEAN([[1,1,1],
                             [1,1,1],
                             [1,1,1]]) == a.is_not_masked }
    is_asserted_by { 0 == a.count_masked }
    is_asserted_by { 9 == a.count_not_masked }

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = 0
    is_asserted_by { true ==  a.has_mask? }           ### mask array is created
    is_asserted_by { CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]) == a.value }
    is_asserted_by { CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]) == a.mask }   ### mask array is created
    is_asserted_by { CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]) == a.is_masked }
    is_asserted_by { CA_BOOLEAN([[1,1,1],
                             [1,1,1],
                             [1,1,1]]) == a.is_not_masked }
    is_asserted_by { 0 == a.count_masked }
    is_asserted_by { 9 == a.count_not_masked }

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    is_asserted_by { true == a.has_mask? }
    is_asserted_by { CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]) == a.value }
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == a.mask }
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == a.is_masked }
    is_asserted_by { CA_BOOLEAN([[1,0,1],
                             [0,0,0],
                             [1,0,1]]) == a.is_not_masked }
    is_asserted_by { 5 == a.count_masked }
    is_asserted_by { 4 == a.count_not_masked }
  end

  example "equality_when_mask_is_added" do
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    is_asserted_by { a.mask == b.mask }
    is_asserted_by { a.is_masked == b.is_masked }
    is_asserted_by { a == b }

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,1,0],
                         [0,1,0]])
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    is_asserted_by { a.mask != b.mask }
    is_asserted_by { a.is_masked != b.is_masked }
    is_asserted_by { a != b }

    # ---
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,0,0],
                         [0,0,0],
                         [0,0,0]])
    is_asserted_by { a.mask != b.mask }
    is_asserted_by { a.is_masked == b.is_masked }
    is_asserted_by { a == b }

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    a.value[1,nil] =  1
    b.value[1,nil] = -1
    is_asserted_by { a.value != b.value }
    is_asserted_by { a.mask == b.mask }
    is_asserted_by { a.is_masked == b.is_masked }
    is_asserted_by { a == b }
  end

  example "has_mask?" do
    # test_basic_feature
  end

  example "any_masked?" do
    #
    a = CA_INT(0..2)
    a.mask = 0
    is_asserted_by { false == a.any_masked? }
    a[1] = UNDEF
    is_asserted_by { true == a.any_masked? }
    a.unmask
    is_asserted_by { false == a.any_masked? }
  end

  example "value" do
    #
    a = CArray.int32(3,3)
    a.mask = 0
    ### can't set mask to value array
    expect { a.value.mask = 1 }.to raise_error(RuntimeError)
  end

  example "mask" do
    # test_basic_feature
    a = CArray.int32(3,3)
    a.mask = 0
    ### can't set mask to mask array
    expect { a.mask.mask = 1 }.to raise_error(RuntimeError)
  end

  example "mask=" do
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]]) ### Though the mask array can hold the value
                                   ### other than 0 or 1, the value 0 means
                                   ### masked and otherwise means not-masked.
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == a.mask }
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == a.is_masked }
    is_asserted_by { CA_BOOLEAN([[1,0,1],
                             [0,0,0],
                             [1,0,1]]) == a.is_not_masked }
    is_asserted_by { 5 == a.count_masked }
    is_asserted_by { 4 == a.count_not_masked }

    # ---
    a = CArray.int32(3,3).seq!
    m = CA_BOOLEAN([[0,1,0],
                    [0,1,0],
                    [0,1,0]])
    m.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    a.mask = m                   ### When masked array is set as mask,
                                 ### masked position is also set as
                                 ### masked elements.
    is_asserted_by { m != a.mask }
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == a.mask }
  end

  example "is_masked" do
    # test_basic_features
  end

  example "is_not_masked" do
    # test_basic_features
  end

  example "count_masked" do
    # test_basic_featrues
  end

  example "count_not_masked" do
    # test_basic_featrues
  end

  example "unmask" do
    # ---
    x = CArray.int32(3,3).seq!
    x.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])

    a = x.to_ca
    b = x.to_ca

    a.unmask()
    is_asserted_by { true == a.has_mask? }   ### never mask eliminated from array
    is_asserted_by { CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]) == a }

    b.unmask(-1)
    is_asserted_by { true == b.has_mask? }   ### never mask eliminated from array
    is_asserted_by { CA_INT32([[0,-1,2],  ### filled with fill_value
                           [-1,-1,-1],
                           [6,-1,8]]) == b }
  end

  example "unmask_copy" do
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    u = a.unmask_copy()
    is_asserted_by { false == u.has_mask? }   ### never mask eliminated from array
    is_asserted_by { CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]) == u }

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    u = a.unmask_copy(-1)
    is_asserted_by { false == u.has_mask? }   ### never mask eliminated from array
    is_asserted_by { CA_INT32([[0,-1,2],   ### filled with fill_value
                           [-1,-1,-1],
                           [6,-1,8]]) == u }
  end

  example "inherit_mask" do
    # ---
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!
    c = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,0,0],
                         [0,1,0]])
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,0,1],
                         [0,0,0]])
    c.mask = CA_BOOLEAN([[0,0,0],
                         [0,1,0],
                         [0,0,0]])
    c.inherit_mask(a,b)
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == c.mask }
  end

  example "inherit_mask_replace" do
    # ---
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!
    c = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,0,0],
                         [0,1,0]])
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,0,1],
                         [0,0,0]])
    c.mask = CA_BOOLEAN([[0,0,0],
                         [0,1,0],
                         [0,0,0]])
    c.inherit_mask_replace(a,b)
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,0,1],
                             [0,1,0]]) == c.mask }

    # ---
    a = CArray.int32(3,3).seq!

  end

  # ----------------------------------------------------------------------

  example "monop" do
    # ---
    a = CArray.float64(3,3) {1}
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    b = -a                              ### example of monop
    is_asserted_by { a.mask == b.mask }
  end

  example "binop" do
    # ---
    a = CArray.float64(3,3) {1}
    b = CArray.float64(3,3) {1}
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,1,0],
                         [0,1,0]])
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    c = a + b                           ### example of binop
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == c.mask }
  end

  example "cmpop" do
    # ---
    a = CArray.float64(3,3) {1}
    b = CArray.float64(3,3) {1}
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,1,0],
                         [0,1,0]])
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    c = a.le(b)                         ### example of binop
    is_asserted_by { CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]) == c.mask }
  end

  # ----------------------------------------------------------------------

  example "basic_stat" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    is_asserted_by { 1 == a.min }
    is_asserted_by { 1 == a.min(:mask_limit => 0) }
    is_asserted_by { 1 == a.min(:mask_limit => 0, :fill_value => -9999) }

    is_asserted_by { 10 == a.max }
    is_asserted_by { 10 == a.max(:mask_limit => 0) }
    is_asserted_by { 10 == a.max(:mask_limit => 0, :fill_value => -9999) }

    is_asserted_by { 55 == a.sum }
    is_asserted_by { 55 == a.sum(:mask_limit => 0) }
    is_asserted_by { 55 == a.sum(:mask_limit => 0, :fill_value => -9999) }

    is_asserted_by { 5.5 == a.mean }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 0) }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 0, :fill_value => -9999) }

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    is_asserted_by { 2 == a.min }
    is_asserted_by { 2 == a.min(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.min(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.min(:mask_limit => 2) }
    is_asserted_by { 2 == a.min(:mask_limit => 3) }
    is_asserted_by { 2 == a.min(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.min(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.min(:mask_limit => 2, :fill_value => -9999) }
    is_asserted_by { 2 == a.min(:mask_limit => 3, :fill_value => -9999) }

    is_asserted_by { 9 == a.max }
    is_asserted_by { 9 == a.max(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.max(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.max(:mask_limit => 2) }
    is_asserted_by { 9 == a.max(:mask_limit => 3) }
    is_asserted_by { 9 == a.max(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.max(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.max(:mask_limit => 2, :fill_value => -9999) }
    is_asserted_by { 9 == a.max(:mask_limit => 3, :fill_value => -9999) }

    is_asserted_by { 44 == a.sum }
    is_asserted_by { 44 == a.sum(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.sum(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.sum(:mask_limit => 2) }
    is_asserted_by { 44 == a.sum(:mask_limit => 3) }
    is_asserted_by { 44 == a.sum(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.sum(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.sum(:mask_limit => 2, :fill_value => -9999) }
    is_asserted_by { 44 == a.sum(:mask_limit => 3, :fill_value => -9999) }

    is_asserted_by { 5.5 == a.mean }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.mean(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.mean(:mask_limit => 2) }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 3) }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.mean(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.mean(:mask_limit => 2, :fill_value => -9999) }
    is_asserted_by { 5.5 == a.mean(:mask_limit => 3, :fill_value => -9999) }

  end

  example "accumulate" do
    # ---
    a = CArray.uint8(256) { 1 }

    is_asserted_by { 0 == a.accumulate }
    is_asserted_by { 0 == a.accumulate(:mask_limit => 0) }
    is_asserted_by { 0 == a.accumulate(:mask_limit => 0, :fill_value => -9999) }

    # ---
    a = CArray.uint8(256) { 1 }
    a[0]   = UNDEF
    a[255] = UNDEF

    is_asserted_by { 254 == a.accumulate() }
    is_asserted_by { 254 == a.accumulate(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.accumulate(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.accumulate(:mask_limit => 2) }
    is_asserted_by { 254 == a.accumulate(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.accumulate(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.accumulate(:mask_limit => 2, :fill_value => -9999) }
  end

  example "variance" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    is_asserted_by { true == (9.16666666666667 - a.variance()) < 0.000001  }
    is_asserted_by { true == (9.16666666666667 - a.variance(:mask_limit=>0)) < 0.000001  }
    is_asserted_by { true == (9.16666666666667 - a.variance(:mask_limit=>0, :fill_value=>-9999)) < 0.000001  }

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    is_asserted_by { 6 == a.variance() }
    is_asserted_by { 6 == a.variance(:mask_limit=>0) }
    is_asserted_by { UNDEF == a.variance(:mask_limit=>1) }
    is_asserted_by { UNDEF == a.variance(:mask_limit=>2) }
    is_asserted_by { 6 == a.variance(:mask_limit=>3) }
    is_asserted_by { 6 == a.variance(:mask_limit=>0, :fill_value=>-9999) }
    is_asserted_by { -9999 == a.variance(:mask_limit=>1, :fill_value=>-9999) }
    is_asserted_by { -9999 == a.variance(:mask_limit=>2, :fill_value=>-9999) }
    is_asserted_by { 6 == a.variance(:mask_limit=>3, :fill_value=>-9999) }

  end

  example "variancep" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    is_asserted_by { true == (8.25 - a.variancep()) < 0.000001  }
    is_asserted_by { true == (8.25 - a.variancep(:mask_limit=>0)) < 0.000001  }
    is_asserted_by { true == (8.25 - a.variancep(:mask_limit=>0, :fill_value=>-9999)) < 0.000001  }

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    is_asserted_by { true == (5.25 - a.variancep()) < 0.000001  }
    is_asserted_by { true == (5.25 - a.variancep(:mask_limit=>0)) < 0.000001  }
    is_asserted_by { UNDEF == a.variancep(:mask_limit=>1) }
    is_asserted_by { UNDEF == a.variancep(:mask_limit=>2) }
    is_asserted_by { true == (5.25 - a.variancep(:mask_limit=>3)) < 0.000001  }
    is_asserted_by { true == (5.25 - a.variancep(:mask_limit=>0, :fill_value=>-9999)) < 0.000001  }
    is_asserted_by { -9999 == a.variancep(:mask_limit=>1, :fill_value=>-9999) }
    is_asserted_by { -9999 == a.variancep(:mask_limit=>2, :fill_value=>-9999) }
    is_asserted_by { true == (5.25 - a.variancep(:mask_limit=>3, :fill_value=>-9999)) < 0.000001  }
  end

  example "prod" do
    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]

    is_asserted_by { 120 == a.prod() }
    is_asserted_by { 120 == a.prod(:mask_limit => 0) }
    is_asserted_by { 120 == a.prod(:mask_limit => 0, :fill_value => -9999) }

    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]
    a[0] = UNDEF
    a[2] = UNDEF                ### [0, 2, _, 4, 5]

    is_asserted_by { 40 == a.prod() }
    is_asserted_by { 40 == a.prod(:mask_limit => 0) }
    is_asserted_by { UNDEF == a.prod(:mask_limit => 1) }
    is_asserted_by { UNDEF == a.prod(:mask_limit => 2) }
    is_asserted_by { 40 == a.prod(:mask_limit => 3) }
    is_asserted_by { 40 == a.prod(:mask_limit => 0, :fill_value => -9999) }
    is_asserted_by { -9999 == a.prod(:mask_limit => 1, :fill_value => -9999) }
    is_asserted_by { -9999 == a.prod(:mask_limit => 2, :fill_value => -9999) }
    is_asserted_by { 40 == a.prod(:mask_limit => 3, :fill_value => -9999) }
  end

  example "wsum" do

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    is_asserted_by { 385 == a.wsum(w) }
    is_asserted_by { 385 == a.wsum(w, 0) }
    is_asserted_by { 385 == a.wsum(w, 0, -9999) }

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    w.mask = 0
    a[0] = UNDEF                 ### [_, 2, ..., 9,10]
    w[9] = UNDEF                 ### [1, 2, ..., 9,_]

#    is_asserted_by { 284 == a.wsum(w) }
#    is_asserted_by { UNDEF == a.wsum(w, 0) }
#    is_asserted_by { UNDEF == a.wsum(w, 1) }
#    is_asserted_by { 284 == a.wsum(w, 2) }

#    is_asserted_by { -9999 == a.wsum(w, 0, -9999) }
#    is_asserted_by { -9999 == a.wsum(w, 1, -9999) }
#    is_asserted_by { 284 == a.wsum(w, 2, -9999) }

  end

  example "cumsum" do
    # ---
    a = CArray.int32(10).seq!(1)
    a[2] = UNDEF
    is_asserted_by { CA_DOUBLE([1, 3, 3, 7, 12, 18, 25, 33, 42, 52]) ==
                 a.cumsum() }
    is_asserted_by { CA_DOUBLE([1, 3, *([UNDEF]*8)]) == 
                 a.cumsum(0) }
    is_asserted_by { CA_DOUBLE([1, 3, *([-9999]*8)]) ==
                 a.cumsum(0, -9999) }
    is_asserted_by { CA_DOUBLE([1, 3, 3, 7, 12, 18, 25, 33, 42, 52]) ==
                 a.cumsum(1) }
  end

  example "cumprod" do
    # ---
    a = CArray.int32(5).seq!(1)
    a[2] = UNDEF
    is_asserted_by { CA_DOUBLE([1, 2, 2, 8, 40]) ==
                 a.cumprod() }
    is_asserted_by { CA_DOUBLE([1, 2, *([UNDEF]*3)]) ==
                 a.cumprod(0) }
    is_asserted_by { CA_DOUBLE([1, 2, *([-9999]*3)]) ==
                 a.cumprod(0, -9999) }
    is_asserted_by { CA_DOUBLE([1, 2, 2, 8, 40]) ==
                 a.cumprod(1) }
  end

  example "count_xxx" do
    # TODO
  end

  example "all_xxx?" do
    # TODO
  end

  example "any_xxx?" do
    # TODO
  end

end
