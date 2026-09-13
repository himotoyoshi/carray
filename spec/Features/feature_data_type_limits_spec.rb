require "carray"
require 'rspec-power_assert'

describe "data type limits" do

  # 2026-09-13
  example "signed integer types bracket their range" do

    is_asserted_by { CArray::Int8::MIN  == -128 }
    is_asserted_by { CArray::Int8::MAX  ==  127 }
    is_asserted_by { CArray::Int16::MIN == -32768 }
    is_asserted_by { CArray::Int16::MAX ==  32767 }
    is_asserted_by { CArray::Int32::MIN == -2147483648 }
    is_asserted_by { CArray::Int32::MAX ==  2147483647 }
    is_asserted_by { CArray::Int64::MIN == -9223372036854775808 }
    is_asserted_by { CArray::Int64::MAX ==  9223372036854775807 }

  end

  # 2026-09-13
  example "unsigned integer types start at zero" do

    is_asserted_by { CArray::UInt8::MIN  == 0 }
    is_asserted_by { CArray::UInt8::MAX  == 255 }
    is_asserted_by { CArray::UInt16::MAX == 65535 }
    is_asserted_by { CArray::UInt32::MAX == 4294967295 }
    is_asserted_by { CArray::UInt64::MAX == 18446744073709551615 }

  end

  # 2026-09-13
  # The limit is the last value the type holds: one step further does
  # not fit, which is the property the constant is claiming.
  example "an integer limit is the last value that fits" do

    a = CArray.int8(1).fill(CArray::Int8::MAX)
    is_asserted_by { a[0] == 127 }

    b = CArray.uint8(1).fill(CArray::UInt8::MAX)
    is_asserted_by { b[0] == 255 }

  end

  # 2026-09-13
  example "float64 limits agree with Ruby's own Float constants" do

    is_asserted_by { CArray::Float64::MAX     == Float::MAX }
    is_asserted_by { CArray::Float64::MIN     == -Float::MAX }
    is_asserted_by { CArray::Float64::EPSILON == Float::EPSILON }
    is_asserted_by { CArray::Float64::TINY    == Float::MIN }

  end

  # 2026-09-13
  # MIN follows NumPy's finfo, not Ruby's Float: it is the bottom of the
  # range, so MIN/MAX bracket a float type the same way they bracket an
  # integer one.  Ruby's Float::MIN is TINY here.
  example "MIN is the bottom of the range, not the smallest positive normal" do

    is_asserted_by { CArray::Float64::MIN < 0 }
    is_asserted_by { CArray::Float64::TINY > 0 }
    is_asserted_by { CArray::Float64::MIN != Float::MIN }

  end

  # 2026-09-13
  example "float32 limits are the binary32 format's" do

    is_asserted_by { CArray::Float32::MAX     ==  3.4028234663852886e+38 }
    is_asserted_by { CArray::Float32::MIN     == -3.4028234663852886e+38 }
    is_asserted_by { CArray::Float32::TINY    ==  1.1754943508222875e-38 }
    is_asserted_by { CArray::Float32::EPSILON ==  1.1920928955078125e-07 }

  end

  # 2026-09-13
  # EPSILON is the step from 1.0 to the next representable value, so it
  # survives a round trip through the type and half of it does not.
  example "EPSILON is the step above 1.0 in that type" do

    a = CArray.float32(2)
    a[0] = 1.0 + CArray::Float32::EPSILON
    a[1] = 1.0 + CArray::Float32::EPSILON / 2
    is_asserted_by { a[0] > 1.0 }
    is_asserted_by { a[1] == 1.0 }

  end

  # 2026-09-13
  # A complex type is a pair of floats and its limits are its
  # component's, which is what np.finfo(np.complex64) answers too.
  example "complex types carry their component's limits" do

    is_asserted_by { CArray::Complex64::EPSILON  == CArray::Float32::EPSILON }
    is_asserted_by { CArray::Complex64::MAX      == CArray::Float32::MAX }
    is_asserted_by { CArray::Complex128::EPSILON == CArray::Float64::EPSILON }
    is_asserted_by { CArray::Complex128::TINY    == CArray::Float64::TINY }

  end

  # 2026-09-13
  # boolean, fixlen and object have no numeric range, so they carry no
  # limits rather than an invented answer.
  example "types without a numeric range carry no limits" do

    expect { CArray::Boolean::MIN }.to raise_error(NameError)
    expect { CArray::Object::MAX }.to raise_error(NameError)
    expect { CArray::Fixlen::EPSILON }.to raise_error(NameError)

  end

  # 2026-09-13
  # The Numo-compatible aliases are the same classes, so they answer the
  # same constants.
  example "the type aliases see the same limits" do

    is_asserted_by { CArray::DFloat::MAX     == CArray::Float64::MAX }
    is_asserted_by { CArray::SFloat::EPSILON == CArray::Float32::EPSILON }
    is_asserted_by { CArray::DComplex::TINY  == CArray::Complex128::TINY }

  end

end
