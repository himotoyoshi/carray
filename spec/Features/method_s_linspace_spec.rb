require "carray"
require 'rspec-power_assert'

describe "CArray.linspace" do

  # 2020-07-10
  example "float range" do

    a = CArray.linspace(0.0,1.0)
    b = CArray.double(100).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2020-07-10
  example "integer range -> float array" do

    a = CArray.linspace(0,1)
    b = CArray.double(100).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2020-07-10
  example "specify number" do

    a = CArray.linspace(0.0,1.0,5)
    b = CArray.double(5).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2026-07-21
  # linspace on an integer subclass matches NumPy's
  # `np.linspace(x1, x2, n, dtype=int)`: values are computed in float
  # with endpoint-hitting step, then floored to the target type.
  example "integer array (NumPy-compatible)" do

    a = CArray::Int32.linspace(0, 10, 5)
    is_asserted_by { a == CA_INT([0, 2, 5, 7, 10]) }

    #  Handles negative direction the same way NumPy does (round
    #  toward -infinity, not toward zero, so -2.5 -> -3).
    b = CArray::Int32.linspace(0, -10, 5)
    is_asserted_by { b == CA_INT([0, -3, -5, -8, -10]) }

  end


end
  