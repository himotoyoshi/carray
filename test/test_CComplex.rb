$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCComplex < Test::Unit::TestCase

  def test_new
    c = CComplex.new(1,2)
    assert_equal(c.real, 1)
    assert_equal(c.imag, 2)
    c = CComplex.new(1)
    assert_equal(c.real, 1)
    assert_equal(c.imag, 0)
  end

  def test_inspect
    c = CComplex.new(1,2)
    assert_equal(c.inspect, "1.0+2.0i")
    c = CComplex.new(1,-2)
    assert_equal(c.inspect, "1.0-2.0i")
    c = CComplex.new(1)
    assert_equal(c.inspect, "1.0+0.0i")
    c = CComplex.new(0,2)
    assert_equal(c.inspect, "0.0+2.0i")
    c = CComplex.new(0,-2)
    assert_equal(c.inspect, "0.0-2.0i")
  end

  def test_to_i
    c = CComplex.new(23.5, 2)
    assert_raise(NoMethodError) {
      c.to_i
    }
  end

  def test_conj
    c = CComplex.new(1, 1)
    d = CComplex.new(1, -1)
    assert_equal(c.conj, d)
    assert_equal(d.conj, c)
  end

  def test_arg
    c = CComplex.new(1, 1)
    assert_equal(c.arg, Math::PI/4)
  end

  def test_abs
    c = CComplex.new(1, 1)
    assert_equal(c.abs, Math::sqrt(2))
  end

  def test_plus
    a = CComplex.new(1, 1)
    b = CComplex.new(-1,-1)
    assert_equal(a + b, 0)
  end

  def test_minus
    a = CComplex.new(1, 1)
    assert_equal(a - a, 0)
  end

  def test_asterisk
    a = CComplex.new(1, 1)
    b = CComplex.new(1, -1)
    assert_equal(a * b, 2)
  end

  def test_slash
    a = CComplex.new(1, 1)
    b = CComplex.new(1, -1)
    assert_equal(a / b, CComplex.new(0,1))
  end

  def test_star2
    a = CComplex.new(1, 1)
    b = CComplex.new(1, -1)
    # assert_equal(a ** 2, 2*CComplex.new(0,1))
  end

end
