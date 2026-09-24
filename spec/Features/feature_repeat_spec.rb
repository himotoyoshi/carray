require "carray"
require 'rspec-power_assert'

describe "CArray#repeat" do

  # 2026-09-13
  example "a per-element count lays each element down that many times" do

    v = CA_INT([10, 20, 30])

    is_asserted_by { v.repeat(CA_INT([1, 1, 1])).to_a == [10, 20, 30] }
    is_asserted_by { v.repeat(CA_INT([2, 2, 2])).to_a == [10, 10, 20, 20, 30, 30] }
    is_asserted_by { v.repeat(CA_INT([3, 1, 2])).to_a == [10, 10, 10, 20, 30, 30] }

  end

  # 2026-09-13
  # A count of zero drops that element, wherever it sits.
  example "a zero count drops its element" do

    v = CA_INT([10, 20, 30])

    is_asserted_by { v.repeat(CA_INT([0, 2, 1])).to_a == [20, 20, 30] }
    is_asserted_by { v.repeat(CA_INT([2, 0, 1])).to_a == [10, 10, 30] }
    is_asserted_by { v.repeat(CA_INT([2, 1, 0])).to_a == [10, 10, 20] }
    is_asserted_by { v.repeat(CA_INT([5, 0, 0])).to_a == [10, 10, 10, 10, 10] }
    is_asserted_by { v.repeat(CA_INT([0, 0, 5])).to_a == [30, 30, 30, 30, 30] }
    is_asserted_by { v.repeat(CA_INT([0, 0, 0])).to_a == [] }

  end

  # 2026-09-13
  example "a single Integer repeats every element alike" do

    v = CA_INT([10, 20, 30])

    is_asserted_by { v.repeat(2).to_a == [10, 10, 20, 20, 30, 30] }
    is_asserted_by { v.repeat(1).to_a == [10, 20, 30] }
    is_asserted_by { v.repeat(0).to_a == [] }
    #  the spelling this replaces
    is_asserted_by { v.repeat(3).to_a == v[:%, 3].flatten.to_a }

  end

  # 2026-09-13
  # repeat keeps the copies of one element together; tile lays the whole
  # array down again.  Close names, different results.
  example "repeat is not tile" do

    v = CA_INT([10, 20, 30])

    is_asserted_by { v.repeat(2).to_a == [10, 10, 20, 20, 30, 30] }
    is_asserted_by { v.tile(2).to_a   == [10, 20, 30, 10, 20, 30] }

  end

  # 2026-09-13
  example "a Ruby Array of counts works too" do

    is_asserted_by { CA_INT([10, 20, 30]).repeat([3, 1, 2]).to_a ==
                     [10, 10, 10, 20, 30, 30] }

  end

  # 2026-09-13
  example "axis: repeats sub-arrays and keeps the other axes" do

    t = CA_INT([[0, 1], [2, 3], [4, 5]])

    is_asserted_by { t.repeat(CA_INT([2, 1, 1]), axis: 0).to_a ==
                     [[0, 1], [0, 1], [2, 3], [4, 5]] }
    is_asserted_by { t.repeat(CA_INT([1, 0, 2]), axis: 0).to_a ==
                     [[0, 1], [4, 5], [4, 5]] }
    is_asserted_by { t.repeat(CA_INT([2, 1]), axis: 1).to_a ==
                     [[0, 0, 1], [2, 2, 3], [4, 4, 5]] }
    is_asserted_by { t.repeat(CA_INT([2, 1]), axis: -1).to_a ==
                     [[0, 0, 1], [2, 2, 3], [4, 4, 5]] }

  end

  # 2026-09-13
  example "without axis: a multi-dimensional receiver goes in flatten order" do

    t = CA_INT([[0, 1], [2, 3], [4, 5]])

    is_asserted_by { t.repeat(2).to_a == [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5] }

  end

  # 2026-09-13
  example "sub-arrays of a 3-D array" do

    w = CArray.int32(2, 3, 4).seq!

    is_asserted_by { w.repeat(CA_INT([2, 0, 1]), axis: 1).shape == [2, 3, 4] }
    is_asserted_by { w.repeat(CA_INT([2, 0, 1]), axis: 1)[0, nil, 0].to_a == [0, 0, 8] }

  end

  # 2026-09-13
  # The result names the receiver's cells rather than copying them.
  example "the result is a view" do

    a = CA_INT([10, 20, 30])
    r = a.repeat(CA_INT([2, 1, 1]))
    r[0] = 99

    is_asserted_by { a[0] == 99 }

  end

  # 2026-09-13
  example "repeat is the inverse of bincount" do

    counts = CA_INT([1, 1, 2, 3, 4, 4, 6]).bincount
    labels = CArray.int32(counts.elements).seq!

    is_asserted_by { labels.repeat(counts).to_a == [1, 1, 2, 3, 4, 4, 6] }

  end

  # 2026-09-13
  example "the mask of the source travels with it" do

    m = CA_INT([1, 2])
    m[1] = UNDEF

    is_asserted_by { m.repeat(CA_INT([1, 2])).is_masked.to_a == [false, true, true] }

  end

  # 2026-09-13
  example "what repeat refuses" do

    v = CA_INT([10, 20, 30])

    expect { v.repeat(CA_INT([1, -1, 1])) }.to raise_error(ArgumentError)
    expect { v.repeat(-1) }.to raise_error(ArgumentError)
    #  one count per element, no more and no fewer
    expect { v.repeat(CA_INT([1, 2])) }.to raise_error(ArgumentError)
    #  a masked count names no number of repetitions
    masked = CA_INT([1, 2, 3])
    masked[1] = UNDEF
    expect { v.repeat(masked) }.to raise_error(ArgumentError)

  end

end
