$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayMask < Test::Unit::TestCase

  def test_basic_features

    # ---
    a = CArray.int32(3,3).seq!
    assert_equal(false, a.has_mask?)           ### mask array is not created
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), a.value)
    assert_equal(0, a.mask)                    ### mask array is not created
    assert_equal(CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]), a.is_masked)
    assert_equal(CA_BOOLEAN([[1,1,1],
                             [1,1,1],
                             [1,1,1]]), a.is_not_masked)
    assert_equal(0, a.count_masked)
    assert_equal(9, a.count_not_masked)

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = 0
    assert_equal(true, a.has_mask?)            ### mask array is created
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), a.value)
    assert_equal(CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]), a.mask)   ### mask array is created
    assert_equal(CA_BOOLEAN([[0,0,0],
                             [0,0,0],
                             [0,0,0]]), a.is_masked)
    assert_equal(CA_BOOLEAN([[1,1,1],
                             [1,1,1],
                             [1,1,1]]), a.is_not_masked)
    assert_equal(0, a.count_masked)
    assert_equal(9, a.count_not_masked)

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    assert_equal(true, a.has_mask?)
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), a.value)
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), a.mask)
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), a.is_masked)
    assert_equal(CA_BOOLEAN([[1,0,1],
                             [0,0,0],
                             [1,0,1]]), a.is_not_masked)
    assert_equal(5, a.count_masked)
    assert_equal(4, a.count_not_masked)
  end

  def test_equality_when_mask_is_added
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    assert_equal(a.mask, b.mask)
    assert_equal(a.is_masked, b.is_masked)
    assert_equal(a, b)

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [0,1,0],
                         [0,1,0]])
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,0,0],
                         [1,1,1],
                         [0,0,0]])
    assert_not_equal(a.mask, b.mask)
    assert_not_equal(a.is_masked, b.is_masked)
    assert_not_equal(a, b)

    # ---
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!
    b.mask = CA_BOOLEAN([[0,0,0],
                         [0,0,0],
                         [0,0,0]])
    assert_not_equal(a.mask, b.mask)
    assert_equal(a.is_masked, b.is_masked)
    assert_equal(a, b)

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
    assert_not_equal(a.value, b.value)
    assert_equal(a.mask, b.mask)
    assert_equal(a.is_masked, b.is_masked)
    assert_equal(a, b)
  end

  def test_has_mask?
    # test_basic_feature
  end

  def test_any_masked?
    #
    a = CA_INT(0..2)
    a.mask = 0
    assert_equal(false, a.any_masked?)
    a[1] = UNDEF
    assert_equal(true, a.any_masked?)
    a.unmask
    assert_equal(false, a.any_masked?)
  end

  def test_value
    #
    a = CArray.int32(3,3)
    a.mask = 0
    assert_raise(RuntimeError) {
      a.value.mask = 1             ### can't set mask to value array
    }
  end

  def test_mask
    # test_basic_feature
    a = CArray.int32(3,3)
    a.mask = 0
    assert_raise(RuntimeError) {
      a.mask.mask = 1              ### can't set mask to mask array
    }
  end

  def test_mask=
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]]) ### Though the mask array can hold the value
                                   ### other than 0 or 1, the value 0 means
                                   ### masked and otherwise means not-masked.
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), a.mask)
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), a.is_masked)
    assert_equal(CA_BOOLEAN([[1,0,1],
                             [0,0,0],
                             [1,0,1]]), a.is_not_masked)
    assert_equal(5, a.count_masked)
    assert_equal(4, a.count_not_masked)

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
    assert_not_equal(m, a.mask)
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), a.mask)
  end

  def test_is_masked
    # test_basic_features
  end

  def test_is_not_masked
    # test_basic_features
  end

  def test_count_masked
    # test_basic_featrues
  end

  def test_count_not_masked
    # test_basic_featrues
  end

  def test_unmask
    # ---
    x = CArray.int32(3,3).seq!
    x.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])

    a = x.to_ca
    b = x.to_ca

    a.unmask()
    assert_equal(true, a.has_mask?)   ### never mask eliminated from array
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), a)

    b.unmask(-1)
    assert_equal(true, b.has_mask?)   ### never mask eliminated from array
    assert_equal(CA_INT32([[0,-1,2],  ### filled with fill_value
                           [-1,-1,-1],
                           [6,-1,8]]), b)
  end

  def test_unmask_copy
    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    u = a.unmask_copy()
    assert_equal(false, u.has_mask?)   ### never mask eliminated from array
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), u)

    # ---
    a = CArray.int32(3,3).seq!
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    u = a.unmask_copy(-1)
    assert_equal(false, u.has_mask?)   ### never mask eliminated from array
    assert_equal(CA_INT32([[0,-1,2],   ### filled with fill_value
                           [-1,-1,-1],
                           [6,-1,8]]), u)
  end

  def test_inherit_mask
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
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), c.mask)
  end

  def test_inherit_mask_replace
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
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,0,1],
                             [0,1,0]]), c.mask)

    # ---
    a = CArray.int32(3,3).seq!

  end

  # ----------------------------------------------------------------------

  def test_monop
    # ---
    a = CArray.float64(3,3) {1}
    a.mask = CA_BOOLEAN([[0,1,0],
                         [1,1,1],
                         [0,1,0]])
    b = -a                              ### example of monop
    assert_equal(a.mask, b.mask)
  end

  def test_binop
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
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), c.mask)
  end

  def test_cmpop
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
    assert_equal(CA_BOOLEAN([[0,1,0],
                             [1,1,1],
                             [0,1,0]]), c.mask)
  end

  # ----------------------------------------------------------------------

  def test_basic_stat
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    assert_equal(1, a.min)
    assert_equal(1, a.min(:mask_limit => 0))
    assert_equal(1, a.min(:mask_limit => 0, :fill_value => -9999))

    assert_equal(10, a.max)
    assert_equal(10, a.max(:mask_limit => 0))
    assert_equal(10, a.max(:mask_limit => 0, :fill_value => -9999))

    assert_equal(55, a.sum)
    assert_equal(55, a.sum(:mask_limit => 0))
    assert_equal(55, a.sum(:mask_limit => 0, :fill_value => -9999))

    assert_equal(5.5, a.mean)
    assert_equal(5.5, a.mean(:mask_limit => 0))
    assert_equal(5.5, a.mean(:mask_limit => 0, :fill_value => -9999))

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    assert_equal(2, a.min)
    assert_equal(2, a.min(:mask_limit => 0))
    assert_equal(UNDEF, a.min(:mask_limit => 1))
    assert_equal(UNDEF, a.min(:mask_limit => 2))
    assert_equal(2, a.min(:mask_limit => 3))
    assert_equal(2, a.min(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.min(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.min(:mask_limit => 2, :fill_value => -9999))
    assert_equal(2, a.min(:mask_limit => 3, :fill_value => -9999))

    assert_equal(9, a.max)
    assert_equal(9, a.max(:mask_limit => 0))
    assert_equal(UNDEF, a.max(:mask_limit => 1))
    assert_equal(UNDEF, a.max(:mask_limit => 2))
    assert_equal(9, a.max(:mask_limit => 3))
    assert_equal(9, a.max(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.max(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.max(:mask_limit => 2, :fill_value => -9999))
    assert_equal(9, a.max(:mask_limit => 3, :fill_value => -9999))

    assert_equal(44, a.sum)
    assert_equal(44, a.sum(:mask_limit => 0))
    assert_equal(UNDEF, a.sum(:mask_limit => 1))
    assert_equal(UNDEF, a.sum(:mask_limit => 2))
    assert_equal(44, a.sum(:mask_limit => 3))
    assert_equal(44, a.sum(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.sum(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.sum(:mask_limit => 2, :fill_value => -9999))
    assert_equal(44, a.sum(:mask_limit => 3, :fill_value => -9999))

    assert_equal(5.5, a.mean)
    assert_equal(5.5, a.mean(:mask_limit => 0))
    assert_equal(UNDEF, a.mean(:mask_limit => 1))
    assert_equal(UNDEF, a.mean(:mask_limit => 2))
    assert_equal(5.5, a.mean(:mask_limit => 3))
    assert_equal(5.5, a.mean(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.mean(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.mean(:mask_limit => 2, :fill_value => -9999))
    assert_equal(5.5, a.mean(:mask_limit => 3, :fill_value => -9999))

  end

  def test_accumulate
    # ---
    a = CArray.uint8(256) { 1 }

    assert_equal(0, a.accumulate)
    assert_equal(0, a.accumulate(:mask_limit => 0))
    assert_equal(0, a.accumulate(:mask_limit => 0, :fill_value => -9999))

    # ---
    a = CArray.uint8(256) { 1 }
    a[0]   = UNDEF
    a[255] = UNDEF

    assert_equal(254, a.accumulate())
    assert_equal(254, a.accumulate(:mask_limit => 0))
    assert_equal(UNDEF, a.accumulate(:mask_limit => 1))
    assert_equal(UNDEF, a.accumulate(:mask_limit => 2))
    assert_equal(254, a.accumulate(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.accumulate(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.accumulate(:mask_limit => 2, :fill_value => -9999))
  end

  def test_variance
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    assert_equal(true, (9.16666666666667 - a.variance()) < 0.000001 )
    assert_equal(true, (9.16666666666667 - a.variance(:mask_limit=>0)) < 0.000001 )
    assert_equal(true, (9.16666666666667 - a.variance(:mask_limit=>0, :fill_value=>-9999)) < 0.000001 )

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    assert_equal(6, a.variance())
    assert_equal(6, a.variance(:mask_limit=>0))
    assert_equal(UNDEF, a.variance(:mask_limit=>1))
    assert_equal(UNDEF, a.variance(:mask_limit=>2))
    assert_equal(6, a.variance(:mask_limit=>3))
    assert_equal(6, a.variance(:mask_limit=>0, :fill_value=>-9999))
    assert_equal(-9999, a.variance(:mask_limit=>1, :fill_value=>-9999))
    assert_equal(-9999, a.variance(:mask_limit=>2, :fill_value=>-9999))
    assert_equal(6, a.variance(:mask_limit=>3, :fill_value=>-9999))

  end

  def test_variancep
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    assert_equal(true, (8.25 - a.variancep()) < 0.000001 )
    assert_equal(true, (8.25 - a.variancep(:mask_limit=>0)) < 0.000001 )
    assert_equal(true, (8.25 - a.variancep(:mask_limit=>0, :fill_value=>-9999)) < 0.000001 )

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    a[0] = UNDEF
    a[9] = UNDEF                 ### [_, 2, ..., 9,_]

    assert_equal(true, (5.25 - a.variancep()) < 0.000001 )
    assert_equal(true, (5.25 - a.variancep(:mask_limit=>0)) < 0.000001 )
    assert_equal(UNDEF, a.variancep(:mask_limit=>1))
    assert_equal(UNDEF, a.variancep(:mask_limit=>2))
    assert_equal(true, (5.25 - a.variancep(:mask_limit=>3)) < 0.000001 )
    assert_equal(true, (5.25 - a.variancep(:mask_limit=>0, :fill_value=>-9999)) < 0.000001 )
    assert_equal(-9999, a.variancep(:mask_limit=>1, :fill_value=>-9999))
    assert_equal(-9999, a.variancep(:mask_limit=>2, :fill_value=>-9999))
    assert_equal(true, (5.25 - a.variancep(:mask_limit=>3, :fill_value=>-9999)) < 0.000001 )
  end

  def test_prod
    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]

    assert_equal(120, a.prod())
    assert_equal(120, a.prod(:mask_limit => 0))
    assert_equal(120, a.prod(:mask_limit => 0, :fill_value => -9999))

    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]
    a[0] = UNDEF
    a[2] = UNDEF                ### [0, 2, _, 4, 5]

    assert_equal(40, a.prod())
    assert_equal(40, a.prod(:mask_limit => 0))
    assert_equal(UNDEF, a.prod(:mask_limit => 1))
    assert_equal(UNDEF, a.prod(:mask_limit => 2))
    assert_equal(40, a.prod(:mask_limit => 3))
    assert_equal(40, a.prod(:mask_limit => 0, :fill_value => -9999))
    assert_equal(-9999, a.prod(:mask_limit => 1, :fill_value => -9999))
    assert_equal(-9999, a.prod(:mask_limit => 2, :fill_value => -9999))
    assert_equal(40, a.prod(:mask_limit => 3, :fill_value => -9999))
  end

  def test_wsum

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]

    assert_equal(385, a.wsum(w))
    assert_equal(385, a.wsum(w, 0))
    assert_equal(385, a.wsum(w, 0, -9999))

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    a.mask = 0
    w.mask = 0
    a[0] = UNDEF                 ### [_, 2, ..., 9,10]
    w[9] = UNDEF                 ### [1, 2, ..., 9,_]

#    assert_equal(284, a.wsum(w))
#    assert_equal(UNDEF, a.wsum(w, 0))
#    assert_equal(UNDEF, a.wsum(w, 1))
#    assert_equal(284, a.wsum(w, 2))

#    assert_equal(-9999, a.wsum(w, 0, -9999))
#    assert_equal(-9999, a.wsum(w, 1, -9999))
#    assert_equal(284, a.wsum(w, 2, -9999))

  end

  def test_cumsum
    # ---
    a = CArray.int32(10).seq!(1)
    a[2] = UNDEF
    assert_equal(CA_DOUBLE([1, 3, 3, 7, 12, 18, 25, 33, 42, 52]),
                 a.cumsum())
    assert_equal(CA_DOUBLE([1, 3, *([UNDEF]*8)]),
                 a.cumsum(0))
    assert_equal(CA_DOUBLE([1, 3, *([-9999]*8)]),
                 a.cumsum(0, -9999))
    assert_equal(CA_DOUBLE([1, 3, 3, 7, 12, 18, 25, 33, 42, 52]),
                 a.cumsum(1))
  end

  def test_cumprod
    # ---
    a = CArray.int32(5).seq!(1)
    a[2] = UNDEF
    assert_equal(CA_DOUBLE([1, 2, 2, 8, 40]),
                 a.cumprod())
    assert_equal(CA_DOUBLE([1, 2, *([UNDEF]*3)]),
                 a.cumprod(0))
    assert_equal(CA_DOUBLE([1, 2, *([-9999]*3)]),
                 a.cumprod(0, -9999))
    assert_equal(CA_DOUBLE([1, 2, 2, 8, 40]),
                 a.cumprod(1))
  end

  def test_count_xxx
    # TODO
  end

  def test_all_xxx?
    # TODO
  end

  def test_any_xxx?
    # TODO
  end

end
