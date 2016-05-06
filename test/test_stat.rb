$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayStat < Test::Unit::TestCase

  def test_min
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.min
    assert_instance_of(Fixnum, s)
    assert_equal(1, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.min
    assert_instance_of(Float, s)
    assert_equal(1, s)

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      assert_raise(CArray::DataTypeError) {
        s = a.min
      }
    end
  end

  def test_min_addr
    # ---
    a = CA_INT32([8,7,6,5,4,5,6,7,8])
    assert_equal(4, a.min_addr)

    # ---
    a = CA_INT32([1,1,1,2,2,2,3,3,3])
    assert_equal(0, a.min_addr)
    assert_equal(6, a.reverse.min_addr)

    # ---
    _ = UNDEF
    a = CA_INT32([_,2,3])
    assert_equal(1, a.min_addr())
    assert_equal(1, a.min_addr(:mask_limit => 0))
    assert_equal(UNDEF, a.min_addr(:mask_limit => 1))
    assert_equal(-9999, a.min_addr(:mask_limit => 1, :fill_value => -9999))
    assert_equal(1, a.min_addr(:mask_limit => 2))
  end

  def test_max
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.max
    assert_instance_of(Fixnum, s)
    assert_equal(10, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.max
    assert_instance_of(Float, s)
    assert_equal(10, s)

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      assert_raise(CArray::DataTypeError) {
        s = a.max
      }
    end
  end

  def test_max_addr
    # ---
    a = CA_INT32([0,1,2,3,4,3,2,1,0])
    assert_equal(4, a.max_addr)

    # ---
    a = CA_INT32([1,1,1,2,2,2,3,3,3])
    assert_equal(6, a.max_addr)
    assert_equal(0, a.reverse.max_addr)

    # ---
    _ = UNDEF
    a = CA_INT32([1,2,_])
    assert_equal(1, a.max_addr())
    assert_equal(1, a.max_addr(:mask_limit => 0))
    assert_equal(UNDEF, a.max_addr(:mask_limit => 1))
    assert_equal(-9999, a.max_addr(:mask_limit => 1, :fill_value => -9999))
    assert_equal(1, a.max_addr(:mask_limit => 2))
  end

  def test_max_and_min_addr
    a = CArray.float(100).span!(1..100).shuffle
    addr1 = a.max_addr
    addr2 = (-a).min_addr
    assert_equal(addr1, addr2)
    assert_equal(100, a[addr1])
  end

  def test_sum
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.sum
    assert_instance_of(Float, s)
    assert_equal(55, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.sum
    assert_instance_of(Float, s)
    assert_equal(55, s)

  end

  def test_prod
    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]
    s = a.prod
    assert_instance_of(Float, s)
    assert_equal(120, s)

    # ---
    a = CArray.float64(5).seq!(1) ### [1, 2, ..., 5]
    s = a.prod
    assert_instance_of(Float, s)
    assert_equal(120, s)

  end

  def test_mean
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.mean
    assert_instance_of(Float, s)
    assert_equal(5.5, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.mean
    assert_instance_of(Float, s)
    assert_equal(5.5, s)

  end

  def test_wmean
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = a.reverse
    s = a.wmean(w)
    assert_equal(4, s)

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = a.reverse
    a[0] = UNDEF
    w[9] = UNDEF
    s = a.wmean(w)
    assert_equal(200.0/44, s)
  end

  def test_cumsum
    # ---
    a = CArray.int32(10).seq!(1)
    assert_equal(CA_DOUBLE([1, 3, 6, 10, 15, 21, 28, 36, 45, 55]), a.cumsum())
  end

  def test_cumprod
    # ---
    a = CArray.int32(5).seq!(1)
    assert_equal(CA_DOUBLE([ 1, 2, 6, 24, 120 ]), a.cumprod())
  end

  def test_variancep
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variancep
    assert_instance_of(Float, s)
    assert_equal(8.25, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variancep
    assert_instance_of(Float, s)
    assert_equal(8.25, s)

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      assert_raise(CArray::DataTypeError) {
        s = a.variancep
      }
    end
  end

  def test_variance
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variance
    assert_instance_of(Float, s)
    assert_equal(true, (9.1666667 - s).abs < 0.00001)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variance
    assert_instance_of(Float, s)
    assert_equal(true, (9.1666667 - s).abs < 0.00001)

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      assert_raise(CArray::DataTypeError) {
        s = a.variance
      }
    end
  end

  def test_wsum
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.wsum(w)
    assert_instance_of(Float, s)
    assert_equal(385, s)

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.wsum(w)
    assert_instance_of(Float, s)
    assert_equal(385, s)

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      w = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      w.real.seq!(1)     ### [1, 2, ..., 10]
      w.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      s = a.wsum(w.conj)
      assert_instance_of(CComplex, s)
      assert_equal(770, s.real)
      assert_equal(0, s.imag)
    end
  end

  def test_accumulate
    # ---
    a = CArray.uint8(255) {1}
    b = CArray.uint8(256) {1}
    assert_equal(255, a.accumulate)
    assert_equal(0,   b.accumulate)

    # ---
    a = CArray.int8(127) {1}
    b = CArray.int8(128) {1}
    c = CArray.int8(255) {1}
    d = CArray.int8(256) {1}
    assert_equal(127,  a.accumulate)
    assert_equal(-128, b.accumulate)
    assert_equal(-1,   c.accumulate)
    assert_equal(0,    d.accumulate)
  end

  def test_count_equal
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    assert_equal(1,a.count_equal(0))
    assert_equal(3,a.count_equal(1))
    assert_equal(4,a.count_equal(2))
    assert_equal(2,a.count_equal(3))
    assert_equal(0,a.count_equal(4))
  end

  def test_count_equiv
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    assert_equal(1,a.count_equiv(0,0.001))
    assert_equal(3,a.count_equiv(1,0.001))
    assert_equal(4,a.count_equiv(2,0.001))
    assert_equal(2,a.count_equiv(3,0.001))
    assert_equal(0,a.count_equiv(4,0.001))

    # ---
    a = CArray.float64(10)
    a[0] = 0.00005
    a[1..3] = 1.00005
    a[4..7] = 2.0001
    a[8..9] = 3.00015          ### [0,1,1,1,2,2,2,2,3,3]

    assert_equal(0,a.count_equiv(0,0.00001))
    assert_equal(0,a.count_equiv(1,0.00001))
    assert_equal(0,a.count_equiv(2,0.00001))
    assert_equal(0,a.count_equiv(3,0.00001))
    assert_equal(0,a.count_equiv(4,0.00001))

    assert_equal(0,a.count_equiv(0,0.0001)) ### comparison with 0 yields false

    assert_equal(3,a.count_equiv(1,0.0001))
    assert_equal(4,a.count_equiv(2,0.0001))
    assert_equal(2,a.count_equiv(3,0.0001))
    assert_equal(0,a.count_equiv(4,0.0001))
  end

  def test_count_close
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    assert_equal(1,a.count_close(0,0.001))
    assert_equal(3,a.count_close(1,0.001))
    assert_equal(4,a.count_close(2,0.001))
    assert_equal(2,a.count_close(3,0.001))
    assert_equal(0,a.count_close(4,0.001))

    # ---
    a = CArray.float64(10)
    a[0] = 0.00005
    a[1..3] = 1.00005
    a[4..7] = 2.00005
    a[8..9] = 3.00005          ### [0,1,1,1,2,2,2,2,3,3]

    assert_equal(0,a.count_close(0,0.00001))
    assert_equal(0,a.count_close(1,0.00001))
    assert_equal(0,a.count_close(2,0.00001))
    assert_equal(0,a.count_close(3,0.00001))
    assert_equal(0,a.count_close(4,0.00001))

    assert_equal(1,a.count_close(0,0.0001))
    assert_equal(3,a.count_close(1,0.0001))
    assert_equal(4,a.count_close(2,0.0001))
    assert_equal(2,a.count_close(3,0.0001))
    assert_equal(0,a.count_close(4,0.0001))
  end

  def test_all_equal
    #---
    a = CArray.int32(3,3) {1}
    assert_equal(false, a.all_equal?(0))
    assert_equal(true, a.all_equal?(1))
  end

  def test_all_equiv
    #---
    a = CArray.float64(3,3) {1.00005}
    assert_equal(false, a.all_equiv?(0, 0.0001))
    assert_equal(true, a.all_equiv?(1,  0.0001))
    assert_equal(false, a.all_equiv?(1, 0.00001))
  end

  def test_all_close
    #---
    a = CArray.float64(3,3) {1.0001}
    assert_equal(false, a.all_close?(0, 0.0001))
    assert_equal(true, a.all_close?(1,  0.0001))
    assert_equal(false, a.all_close?(1, 0.00001))
  end

  def test_any_equal
    #---
    a = CArray.int32(3,3)
    a[1,1] = 1
    assert_equal(true, a.any_equal?(0))
    assert_equal(true, a.any_equal?(1))
  end

  def test_any_equiv
    #---
    a = CArray.float64(3,3) { 0.00005 }
    a[1,1] = 1.00005
    assert_equal(false, a.any_equiv?(0, 0.0001))
    assert_equal(true, a.any_equiv?(1,  0.0001))
    assert_equal(false, a.any_equiv?(1, 0.00001))
  end

  def test_any_close
    #---
    a = CArray.float64(3,3) { 0.0001 }
    a[1,1] = 1.0001
    assert_equal(true, a.any_close?(0, 0.0001))
    assert_equal(true, a.any_close?(1,  0.0001))
    assert_equal(false, a.any_close?(1, 0.00001))
  end

  def test_shuffle!
    # ---
    a = CArray.int(10).seq!(1)
    b = a.shuffle
    assert_equal(a.sum, b.sum)
    assert_equal(a.mean, b.mean)
  end

end
