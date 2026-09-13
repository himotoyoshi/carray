require "carray"
require 'rspec-power_assert'

describe "value-hash discovery over sub-arrays (along:)" do

  # 2026-09-13
  example "unique(along: 0) gives the distinct rows in first-appearance order" do

    z = CA_INT([[0, 1, 1],
                [1, 0, 0],
                [0, 1, 1],
                [1, 1, 0],
                [1, 0, 0]])

    is_asserted_by { z.unique(along: 0).to_a == [[0, 1, 1], [1, 0, 0], [1, 1, 0]] }
    is_asserted_by { z.nunique(along: 0) == 3 }

  end

  # 2026-09-13
  example "mask_duplicates(along: 0) masks a repeated row whole" do

    z = CA_INT([[0, 1], [1, 0], [0, 1]])

    is_asserted_by { z.mask_duplicates(along: 0).is_masked.to_a ==
                     [[false, false], [false, false], [true, true]] }

  end

  # 2026-09-13
  example "along: 1 compares columns" do

    c = CA_INT([[0, 1, 0],
                [1, 0, 1],
                [2, 3, 2]])       # column 2 repeats column 0

    is_asserted_by { c.unique(along: 1).to_a == [[0, 1], [1, 0], [2, 3]] }
    is_asserted_by { c.nunique(along: 1) == 2 }

  end

  # 2026-09-13
  # along: and axis: ask different questions: along: compares whole
  # sub-arrays, axis: counts the values inside each fiber.
  example "axis: keeps its own meaning" do

    c = CA_INT([[0, 1, 0],
                [1, 0, 1],
                [2, 3, 2]])

    is_asserted_by { c.nunique(axis: 1).to_a == [2, 2, 2] }
    expect { c.nunique(axis: 1, along: 0) }.to raise_error(ArgumentError)
    expect { c.mask_duplicates(axis: 1, along: 0) }.to raise_error(ArgumentError)

  end

  # 2026-09-13
  example "sub-arrays of a 3-D array" do

    v = CArray.int32(4, 2, 3).seq!
    v[2, nil, nil] = v[0, nil, nil]        # slab 2 repeats slab 0

    is_asserted_by { v.nunique(along: 0) == 3 }
    is_asserted_by { v.unique(along: 0).shape == [3, 2, 3] }

  end

  # 2026-09-13
  # The bytes of a sub-array only mean anything once it is contiguous,
  # which a transpose is not.
  example "a transposed source is read through its own axes" do

    t = CA_INT([[0, 1, 2], [3, 4, 5], [6, 7, 8]]).transpose

    is_asserted_by { t.unique(along: 0).to_a == [[0, 3, 6], [1, 4, 7], [2, 5, 8]] }

  end

  # 2026-09-13
  example "a block view is read through its own axes" do

    big = CArray.int32(5, 4).seq!

    is_asserted_by { big[1..3, 0..2].unique(along: 0).to_a ==
                     [[4, 5, 6], [8, 9, 10], [12, 13, 14]] }

  end

  # 2026-09-13
  # The family's distinctness rule, widened from a cell to a sub-array:
  # every NaN is one value and -0.0 is +0.0, neither of which is byte
  # equality.
  example "float sub-arrays follow the value rule, not byte equality" do

    nan = Float::NAN
    f = CA_DOUBLE([[nan,  1.0],
                   [-nan, 1.0],      # a different NaN bit pattern
                   [0.0,  2.0],
                   [-0.0, 2.0]])

    is_asserted_by { f.nunique(along: 0) == 2 }

  end

  # 2026-09-13
  example "the source is not normalised in place" do

    f = CA_DOUBLE([[-0.0, 1.0], [0.0, 1.0]])
    f.nunique(along: 0)

    is_asserted_by { f[0, 0].to_s == "-0.0" }

  end

  # 2026-09-13
  # A sub-array holding a masked cell does not participate: it is not
  # counted, never appears in unique, and keeps the mask it came with.
  example "a sub-array with a masked cell does not participate" do

    m = CA_INT([[1, 2], [1, 2], [9, 9]])
    m[2, 0] = UNDEF

    is_asserted_by { m.nunique(along: 0) == 1 }
    is_asserted_by { m.unique(along: 0).to_a == [[1, 2]] }
    is_asserted_by { m.mask_duplicates(along: 0).is_masked.to_a ==
                     [[false, false], [true, true], [true, false]] }

  end

  # 2026-09-13
  example "boolean and fixlen sub-arrays" do

    b = CA_BOOLEAN([[true, false], [true, false], [false, true]])
    is_asserted_by { b.nunique(along: 0) == 2 }

    fx = CA_FIXLEN([["ab", "cd"], ["ab", "cd"], ["ab", "zz"]], bytes: 2)
    is_asserted_by { fx.nunique(along: 0) == 2 }

  end

  # 2026-09-13
  # The result names the surviving sub-arrays of the receiver rather
  # than copying them.
  example "unique(along:) returns a view" do

    w = CA_INT([[1, 2], [1, 2], [3, 4]])
    u = w.unique(along: 0)
    u[0, 0] = 99

    is_asserted_by { w[0, 0] == 99 }

  end

  # 2026-09-13
  example "what along: refuses" do

    z = CA_INT([[1, 2], [1, 2]])

    #  an object array compares by identity, not by value
    expect { CA_OBJECT([[1, 2], [1, 2]]).unique(along: 0) }.to raise_error(ArgumentError)
    #  a 1-D array has no sub-arrays
    expect { CA_INT([1, 2, 3]).unique(along: 0) }.to raise_error(ArgumentError)
    #  sub-arrays have no order to sort by
    expect { z.unique(along: 0, sort: true) }.to raise_error(ArgumentError)
    #  and the axis still has to exist
    expect { z.unique(along: 5) }.to raise_error(StandardError)

  end

end
