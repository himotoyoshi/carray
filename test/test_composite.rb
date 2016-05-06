$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayComposite < Test::Unit::TestCase

  def test_combine
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
    assert_equal(y, x)

    # ---
    y = CA_INT32([
                  [1,1,2,2,3,3,4,4],
                  [1,1,2,2,3,3,4,4]
                 ])
    x = CArray.combine(CA_INT32, [4], list, -1)
    assert_equal(y, x)
    x = CArray.combine(CA_INT32, [4], list, 1)
    assert_equal(y, x)

    # ---
    y = CA_INT32([
                  [1,1,2,2],
                  [1,1,2,2],
                  [3,3,4,4],
                  [3,3,4,4],
                 ])
    x = CArray.combine(CA_INT32, [2,2], list, 0)
    assert_equal(y, x)
    x = CArray.combine(CA_INT32, [2,2], list, -1)
    assert_equal(y, x)

    assert_raise(RuntimeError) {
      CArray.combine(CA_INT32, [2,2], list, 1)
    }

  end

  def test_composite
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
    assert_equal(y, x)

    # ---
    y = CA_INT32([ [ [ 1, 2, 3, 4 ],
                     [ 1, 2, 3, 4 ] ],
                   [ [ 1, 2, 3, 4 ],
                     [ 1, 2, 3, 4 ] ] ])
    x = CArray.composite(CA_INT32, [4], list, -1)
    assert_equal(y, x)

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
    assert_equal(y, x)

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
    assert_equal(y, x)

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
    assert_equal(y, x)

    x = CArray.composite(CA_INT32, [2,2], list, -1)
    assert_equal(y, x)

  end

end
