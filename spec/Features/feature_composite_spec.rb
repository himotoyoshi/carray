
require 'carray'
require "rspec-power_assert"

describe "TestCArrayComposite " do

  example "combine" do
    a1 = CArray.int32(2,2){1}
    a2 = CArray.int32(2,2){2}
    a3 = CArray.int32(2,2){3}
    a4 = CArray.int32(2,2){4}
    list = [a1, a2, a3, a4]

    # ---
    y = CA_INT32([
                  [1,1],
                  [1,1],
                  [2,2],
                  [2,2],
                  [3,3],
                  [3,3],
                  [4,4],
                  [4,4],
                 ])
    x = CArray.combine(CA_INT32, [4], list, 0)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([
                  [1,1,2,2,3,3,4,4],
                  [1,1,2,2,3,3,4,4]
                 ])
    x = CArray.combine(CA_INT32, [4], list, -1)
    is_asserted_by { y == x }
    x = CArray.combine(CA_INT32, [4], list, 1)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([
                  [1,1,2,2],
                  [1,1,2,2],
                  [3,3,4,4],
                  [3,3,4,4],
                 ])
    x = CArray.combine(CA_INT32, [2,2], list, 0)
    is_asserted_by { y == x }
    x = CArray.combine(CA_INT32, [2,2], list, -1)
    is_asserted_by { y == x }

    expect {
      CArray.combine(CA_INT32, [2,2], list, 1)
    }.to raise_error(RuntimeError)

  end

  example "composite" do
    a1 = CArray.int32(2,2){1}
    a2 = CArray.int32(2,2){2}
    a3 = CArray.int32(2,2){3}
    a4 = CArray.int32(2,2){4}
    list = [a1, a2, a3, a4]

    # ---
    y = CA_INT32([ [ [ 1, 1 ],
                     [ 1, 1 ] ],
                   [ [ 2, 2 ],
                     [ 2, 2 ] ],
                   [ [ 3, 3 ],
                     [ 3, 3 ] ],
                   [ [ 4, 4 ],
                     [ 4, 4 ] ] ])
    x = CArray.composite(CA_INT32, [4], list, 0)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([ [ [ 1, 2, 3, 4 ],
                     [ 1, 2, 3, 4 ] ],
                   [ [ 1, 2, 3, 4 ],
                     [ 1, 2, 3, 4 ] ] ])
    x = CArray.composite(CA_INT32, [4], list, -1)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([ [ [ [ 1, 1 ],
                       [ 1, 1 ] ],
                     [ [ 2, 2 ],
                       [ 2, 2 ] ] ],
                   [ [ [ 3, 3 ],
                       [ 3, 3 ] ],
                     [ [ 4, 4 ],
                       [ 4, 4 ] ] ] ])
    x = CArray.composite(CA_INT32, [2,2], list, 0)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([ [ [ [ 1, 1 ],
                       [ 2, 2 ] ],
                     [ [ 3, 3 ],
                       [ 4, 4 ] ] ],
                   [ [ [ 1, 1 ],
                       [ 2, 2 ] ],
                     [ [ 3, 3 ],
                       [ 4, 4 ] ] ] ])
    x = CArray.composite(CA_INT32, [2,2], list, 1)
    is_asserted_by { y == x }

    # ---
    y = CA_INT32([ [ [ [ 1, 2 ],
                       [ 3, 4 ] ],
                     [ [ 1, 2 ],
                       [ 3, 4 ] ] ],
                   [ [ [ 1, 2 ],
                       [ 3, 4 ] ],
                     [ [ 1, 2 ],
                       [ 3, 4 ] ] ] ])
    x = CArray.composite(CA_INT32, [2,2], list, 2)
    is_asserted_by { y == x }

    x = CArray.composite(CA_INT32, [2,2], list, -1)
    is_asserted_by { y == x }

  end

end
