require "carray"
require 'rspec-power_assert'

describe "CArray#span" do

  # 2020-07-10
  example "float range" do

    a = CArray.double(11).span(0..5)

    is_asserted_by { a == CA_DOUBLE([0.0,0.5,1.0,1.5,2.0,2.5,3.0,3.5,4.0,4.5,5.0]) }

  end

  # 2026-07-21
  # Integer arrays are ambiguous — "N evenly-spaced integers" has two
  # distinct meanings (endpoints-hitting vs bucket distribution).  span
  # rejects integer arrays and asks the caller to pick one of the two
  # documented idioms.
  example "integer array raises" do

    is_asserted_by { expect { CArray.int(10).span(1..10) }.to raise_error(ArgumentError) }
    is_asserted_by { expect { CArray.int(10).span(1..5)  }.to raise_error(ArgumentError) }
    is_asserted_by { expect { CArray.int(10).span(1...11) }.to raise_error(ArgumentError) }

  end

  # 2026-07-21
  # (A) N points with both endpoints hitting exactly.
  example "integer endpoints via seq * (b-a) / (N-1) + a" do

    n = 10
    a, b = 1, 10
    r = CArray.int(n).seq * (b - a) / (n - 1) + a

    is_asserted_by { r[0]  == a }
    is_asserted_by { r[-1] == b }
    is_asserted_by { r == CA_INT([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) }

  end

  # 2026-07-21
  # (B) N labels distributed uniformly over range values.
  example "integer bucket distribution via seq * (b-a+1) / N + a" do

    n = 10
    a, b = 1, 5
    r = CArray.int(n).seq * (b - a + 1) / n + a

    is_asserted_by { r == CA_INT([1, 1, 2, 2, 3, 3, 4, 4, 5, 5]) }

  end

end
