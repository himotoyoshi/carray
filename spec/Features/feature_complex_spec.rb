
require 'carray'
require "rspec-power_assert"

describe "TestComplex " do

  example "complex" do
    a = CArray.complex(3,3) { 1 + 2*CI }
    is_asserted_by { a.real == CArray.float(3, 3) { 1 } }
    is_asserted_by { a.imag == CArray.float(3, 3) { 2 } }
    a.real[] = -1
    a.imag[] = -2
    is_asserted_by { a.real == CArray.float(3, 3) { -1 } }
    is_asserted_by { a.imag == CArray.float(3, 3) { -2 } }
  end

  example "dcomplex" do
    a = CArray.dcomplex(3,3) { 1 + 2*CI }
    is_asserted_by { a.real == CArray.double(3, 3) { 1 } }
    is_asserted_by { a.imag == CArray.double(3, 3) { 2 } }
    a.real = -1
    a.imag = -2
    is_asserted_by { a.real == CArray.double(3, 3) { -1 } }
    is_asserted_by { a.imag == CArray.double(3, 3) { -2 } }
  end

  example "conj" do
    a = CArray.complex(3,3) { 1 + 2*CI }
    a.conj!
    is_asserted_by { a.real == CArray.float(3, 3) { 1 } }
    is_asserted_by { a.imag == CArray.float(3, 3) { -2 } }
  end

  example "arg" do
    a = CArray.complex(3,3) { 1 + 2*CI }
    a.conj!
    is_asserted_by { a.real == CArray.float(3, 3) { 1 } }
    is_asserted_by { a.imag == CArray.float(3, 3) { -2 } }
  end


end
