# spec_ai/test_real_imag_memo_owner.rb
#
# `real` and `imag` keep the view they return, so that repeated calls give
# the same object.  `dup` and `clone` copy instance variables, so the copy
# used to inherit the original's views: `b = a.dup; b.real = 100` wrote
# into a and left b alone.  The kept views belong to the array they were
# made for, and a copy makes its own.

require "test/unit"
require "carray"

class TestRealImagMemoOwner < Test::Unit::TestCase

  def complex
    CArray.cmplx128(3) { |i| Complex(i, 10 + i) }
  end

  def test_same_object_on_repeated_calls
    a = complex
    assert_same a.real, a.real
    assert_same a.imag, a.imag
  end

  def test_dup_writes_to_itself
    a = complex
    a.real ; a.imag
    b = a.dup
    b.real = 100
    b.imag = -1
    assert_equal [Complex(0, 10), Complex(1, 11), Complex(2, 12)], a.to_a
    assert_equal [Complex(100, -1)] * 3, b.to_a
  end

  def test_clone_writes_to_itself
    a = complex
    a.real ; a.imag
    c = a.clone
    c.real = 100
    c.imag = -1
    assert_equal [Complex(0, 10), Complex(1, 11), Complex(2, 12)], a.to_a
    assert_equal [Complex(100, -1)] * 3, c.to_a
  end

  def test_dup_of_a_view
    a = complex
    v = a[0..1]
    v.real
    w = v.dup
    assert_not_same v.real, w.real
    w.real = 7                      # a view's dup shares the parent, by design
    assert_equal [7.0, 7.0, 2.0], a.real.to_a
  end

  def test_real_array
    x = CArray.float64(3).seq!
    x.real ; x.imag
    y = x.dup
    assert_not_same x.imag, y.imag
    y.real[0] = 9.0
    assert_equal [0.0, 1.0, 2.0], x.to_a
    assert_equal [9.0, 1.0, 2.0], y.to_a
  end

end
