$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestComplex < Test::Unit::TestCase

  def test_complex
    a = CArray.complex(3,3) { 1 + 2*CI }
    assert_equal(a.real, CArray.float(3,3) { 1 })
    assert_equal(a.imag, CArray.float(3,3) { 2 })
    a.real[] = -1
    a.imag[] = -2
    assert_equal(a.real, CArray.float(3,3) { -1 })
    assert_equal(a.imag, CArray.float(3,3) { -2 })
  end

  def test_dcomplex
    a = CArray.dcomplex(3,3) { 1 + 2*CI }
    assert_equal(a.real, CArray.double(3,3) { 1 })
    assert_equal(a.imag, CArray.double(3,3) { 2 })
    a.real = -1
    a.imag = -2
    assert_equal(a.real, CArray.double(3,3) { -1 })
    assert_equal(a.imag, CArray.double(3,3) { -2 })
  end

  def test_conj
    a = CArray.complex(3,3) { 1 + 2*CI }
    a.conj!
    assert_equal(a.real, CArray.float(3,3) { 1 })
    assert_equal(a.imag, CArray.float(3,3) { -2 })
  end

  def test_arg
    a = CArray.complex(3,3) { 1 + 2*CI }
    a.conj!
    assert_equal(a.real, CArray.float(3,3) { 1 })
    assert_equal(a.imag, CArray.float(3,3) { -2 })
  end


end
