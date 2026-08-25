
require 'carray'
require "rspec-power_assert"

describe "TestCArrayStat " do

  example "min" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.min
    #assert_instance_of(Integer, s)
    is_asserted_by {  1 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.min
    is_asserted_by { s.class == Float }
    is_asserted_by { 1 == s }

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      expect { a.min }.to raise_error(CArray::DataTypeError)
    end
  end

  example "min_index" do
    # ---
    a = CA_INT32([8,7,6,5,4,5,6,7,8])
    is_asserted_by {  4 == a.min_index }

    # ---
    a = CA_INT32([1,1,1,2,2,2,3,3,3])
    is_asserted_by {  0 == a.min_index }
    is_asserted_by {  6 == a.reverse.min_index }

    # ---
    _ = UNDEF
    a = CA_INT32([_,2,3])
    is_asserted_by {  1 == a.min_index }
  end

  example "max" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.max
    #assert_instance_of(Integer, s)
    is_asserted_by {  10 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.max
    is_asserted_by { s.class == Float }
    is_asserted_by {  10 == s }

    # ---
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      expect { a.max }.to raise_error(CArray::DataTypeError)
    end
  end

  example "max_index" do
    # ---
    a = CA_INT32([0,1,2,3,4,3,2,1,0])
    is_asserted_by {  4 == a.max_index }

    # ---
    a = CA_INT32([1,1,1,2,2,2,3,3,3])
    is_asserted_by {  6 == a.max_index }
    is_asserted_by {  0 == a.reverse.max_index }

    # ---
    _ = UNDEF
    a = CA_INT32([1,2,_])
    is_asserted_by {  1 == a.max_index }
  end

#  example "max_and_min_addr" do
#    a = CArray.float(100).span!(1..100).shuffle
#    addr1 = a.max_addr
#    addr2 = (-a).min_addr
#    is_asserted_by { addr1, addr2)
#    is_asserted_by { 100, a[addr1])
#  end

  example "sum" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.sum
    is_asserted_by { s.class == Float }
    is_asserted_by {  55 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.sum
    is_asserted_by { s.class == Float }
    is_asserted_by {  55 == s }

  end

  example "prod" do
    # ---
    a = CArray.int32(5).seq!(1) ### [1, 2, ..., 5]
    s = a.prod
    is_asserted_by { s.class == Float }
    is_asserted_by {  120 == s }

    # ---
    a = CArray.float64(5).seq!(1) ### [1, 2, ..., 5]
    s = a.prod
    is_asserted_by { s.class == Float }
    is_asserted_by {  120 == s }

  end

  example "mean" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.mean
    is_asserted_by { s.class == Float }
    is_asserted_by {  5.5 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.mean
    is_asserted_by { s.class == Float }
    is_asserted_by {  5.5 == s }

  end

  example "wmean" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = a.reverse
    s = a.wmean(w)
    is_asserted_by {  4 == s }

    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = a.reverse
    a[0] = UNDEF
    w[9] = UNDEF
    s = a.wmean(w)
    is_asserted_by {  (200.0 / 44) == s }
  end

  example "cumsum" do
    # ---
    a = CArray.int32(10).seq!(1)
    is_asserted_by {  CA_DOUBLE([1, 3, 6, 10, 15, 21, 28, 36, 45, 55]) == a.cumsum }
  end

  example "cumprod" do
    # ---
    a = CArray.int32(5).seq!(1)
    is_asserted_by {  CA_DOUBLE([1, 2, 6, 24, 120]) == a.cumprod }
  end

  example "variancep" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variancep
    is_asserted_by { s.class == Float }
    is_asserted_by {  8.25 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variancep
    is_asserted_by { s.class == Float }
    is_asserted_by {  8.25 == s }

    # ---
    # 3.0: complex variance is the standard E[|Z - mean|^2] (real-valued).
    # Legacy raised DataTypeError; mkkernel-generated kernel computes the
    # mathematically standard definition.
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      s = a.variancep
      is_asserted_by { s.class == Float }
      is_asserted_by { 16.5 == s }   ### 2 * real variance (symmetric)
    end
  end

  example "variance" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variance
    is_asserted_by { s.class == Float }
    is_asserted_by {  true == ((9.1666667 - s).abs < 1.0e-05) }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.variance
    is_asserted_by { s.class == Float }
    is_asserted_by {  true == ((9.1666667 - s).abs < 1.0e-05) }

    # ---
    # 3.0: see variancep note above.
    if CArray::HAVE_COMPLEX
      a = CArray.cmplx128(10)
      a.real.seq!(1)     ### [1, 2, ..., 10]
      a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
      s = a.variance
      is_asserted_by { s.class == Float }
      is_asserted_by { true == ((18.3333333 - s).abs < 1.0e-05) }
    end
  end

  example "wsum" do
    # ---
    a = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.int32(10).seq!(1) ### [1, 2, ..., 10]
    s = a.wsum(w)
    is_asserted_by { s.class == Float }
    is_asserted_by {  385 == s }

    # ---
    a = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    w = CArray.float64(10).seq!(1) ### [1, 2, ..., 10]
    s = a.wsum(w)
    is_asserted_by { s.class == Float }
    is_asserted_by {  385 == s }

    # W.2 (2026-06-04): complex (CMPLX64/CMPLX128) wsum support dropped in
    # the mkkernel migration (= ALL_NUMERIC + :raise fallback).  Re-add via
    # demand-driven complex specialization (= mkkernel reduce_complex form
    # or dedicated complex array_arg path).
    # ---
    # if CArray::HAVE_COMPLEX
    #   a = CArray.cmplx128(10)
    #   w = CArray.cmplx128(10)
    #   a.real.seq!(1)     ### [1, 2, ..., 10]
    #   a.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
    #   w.real.seq!(1)     ### [1, 2, ..., 10]
    #   w.imag.seq!(-1,-1) ### [-1, -2, ..., -10]
    #   s = a.wsum(w.conj)
    #   is_asserted_by { s.class == Complex }
    #   is_asserted_by {  770 == s.real }
    #   is_asserted_by {  0 == s.imag }
    # end
  end

  example "accumulate" do
    # ---
    a = CArray.uint8(255) {1}
    b = CArray.uint8(256) {1}
    is_asserted_by {  255 == a.accumulate }
    is_asserted_by {  0 == b.accumulate }

    # ---
    a = CArray.int8(127) {1}
    b = CArray.int8(128) {1}
    c = CArray.int8(255) {1}
    d = CArray.int8(256) {1}
    is_asserted_by {  127 == a.accumulate }
    is_asserted_by {  (-128) == b.accumulate }
    is_asserted_by {  (-1) == c.accumulate }
    is_asserted_by {  0 == d.accumulate }
  end

  example "count_equal" do
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    is_asserted_by {  1 == a.count(0) }
    is_asserted_by {  3 == a.count(1) }
    is_asserted_by {  4 == a.count(2) }
    is_asserted_by {  2 == a.count(3) }
    is_asserted_by {  0 == a.count(4) }
  end

  example "count_equiv" do
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    is_asserted_by {  1 == a.is_equiv(0,  0.001).count(true) }
    is_asserted_by {  3 == a.is_equiv(1,  0.001).count(true) }
    is_asserted_by {  4 == a.is_equiv(2,  0.001).count(true) }
    is_asserted_by {  2 == a.is_equiv(3,  0.001).count(true) }
    is_asserted_by {  0 == a.is_equiv(4,  0.001).count(true) }

    # ---
    a = CArray.float64(10)
    a[0] = 0.00005
    a[1..3] = 1.00005
    a[4..7] = 2.0001
    a[8..9] = 3.00015          ### [0,1,1,1,2,2,2,2,3,3]

    is_asserted_by {  0 == a.is_equiv(0,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_equiv(1,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_equiv(2,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_equiv(3,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_equiv(4,  1.0e-05).count(true) }

    is_asserted_by {  0 == a.is_equiv(0,  0.0001).count(true) }

    is_asserted_by {  3 == a.is_equiv(1,  0.0001).count(true) }
    is_asserted_by {  4 == a.is_equiv(2,  0.0001).count(true) }
    is_asserted_by {  2 == a.is_equiv(3,  0.0001).count(true) }
    is_asserted_by {  0 == a.is_equiv(4,  0.0001).count(true) }
  end

  example "count_close" do
    # ---
    a = CArray.int32(10)
    a[0] = 0
    a[1..3] = 1
    a[4..7] = 2
    a[8..9] = 3          ### [0,1,1,1,2,2,2,2,3,3]

    is_asserted_by {  1 == a.is_close(0,  0.001).count(true) }
    is_asserted_by {  3 == a.is_close(1,  0.001).count(true) }
    is_asserted_by {  4 == a.is_close(2,  0.001).count(true) }
    is_asserted_by {  2 == a.is_close(3,  0.001).count(true) }
    is_asserted_by {  0 == a.is_close(4,  0.001).count(true) }

    # ---
    a = CArray.float64(10)
    a[0] = 0.00005
    a[1..3] = 1.00005
    a[4..7] = 2.00005
    a[8..9] = 3.00005          ### [0,1,1,1,2,2,2,2,3,3]

    is_asserted_by {  0 == a.is_close(0,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_close(1,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_close(2,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_close(3,  1.0e-05).count(true) }
    is_asserted_by {  0 == a.is_close(4,  1.0e-05).count(true) }

    is_asserted_by {  1 == a.is_close(0,  0.0001).count(true) }
    is_asserted_by {  3 == a.is_close(1,  0.0001).count(true) }
    is_asserted_by {  4 == a.is_close(2,  0.0001).count(true) }
    is_asserted_by {  2 == a.is_close(3,  0.0001).count(true) }
    is_asserted_by {  0 == a.is_close(4,  0.0001).count(true) }
  end

end
