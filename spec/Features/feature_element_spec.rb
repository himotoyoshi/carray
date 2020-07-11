require 'carray'
require 'rspec-power_assert'

describe "Feature: Element" do

  example "set_unset" do
    #
    a = CArray.boolean(3,3) {0}
    a.set(1,1)
    is_asserted_by {  CA_BOOLEAN([[0, 0, 0], [0, 1, 0], [0, 0, 0]]) == a }

    #
    a = CArray.boolean(3,3) {0}
    a.set(4)
    is_asserted_by {  CA_BOOLEAN([[0, 0, 0], [0, 1, 0], [0, 0, 0]]) == a }

    #
    a = CArray.boolean(3,3) {1}
    a.unset(1,1)
    is_asserted_by {  CA_BOOLEAN([[1, 1, 1], [1, 0, 1], [1, 1, 1]]) == a }

    #
    a = CArray.boolean(3,3) {1}
    a.unset(4)
    is_asserted_by {  CA_BOOLEAN([[1, 1, 1], [1, 0, 1], [1, 1, 1]]) == a }
  end

  example "elem_swap" do
    #
    a = CArray.int(3,3).seq!
    a.elem_swap([1,1], [-1,-1])
    is_asserted_by {  8 == a[1, 1] }
    is_asserted_by {  4 == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    a.elem_swap([1,1], [-1,-1])
    is_asserted_by {  8 == a[1, 1] }
    is_asserted_by {  UNDEF == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a.elem_swap(0, -1)
    is_asserted_by {  8 == a[0, 0] }
    is_asserted_by {  0 == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a[0,0] = UNDEF
    a.elem_swap(0, -1)
    is_asserted_by {  8 == a[0, 0] }
    is_asserted_by {  UNDEF == a[-1, -1] }

  end

  example "elem_copy" do
    #
    a = CArray.int(3,3).seq!
    a.elem_copy([1,1], [-1,-1])
    is_asserted_by {  4 == a[1, 1] }
    is_asserted_by {  4 == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    a.elem_copy([1,1], [-1,-1])
    is_asserted_by {  UNDEF == a[1, 1] }
    is_asserted_by {  UNDEF == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a.elem_copy(0, -1)
    is_asserted_by {  0 == a[0, 0] }
    is_asserted_by {  0 == a[-1, -1] }

    #
    a = CArray.int(3,3).seq!
    a[0,0] = UNDEF
    a.elem_copy(0, -1)
    is_asserted_by {  UNDEF == a[0, 0] }
    is_asserted_by {  UNDEF == a[-1, -1] }

  end

  example "elem_fetch" do
    #
    a = CArray.int(3,3).seq!
    is_asserted_by {  4 == a.elem_fetch([1, 1]) }
    a[1,1] = UNDEF
    is_asserted_by {  UNDEF == a.elem_fetch([1, 1]) }

    #
    a = CArray.int(3,3).seq!
    is_asserted_by {  4 == a.elem_fetch(4) }
    a[1,1] = UNDEF
    is_asserted_by {  UNDEF == a.elem_fetch(4) }
  end

  example "elem_store" do
    #
    a = CArray.int(3,3).seq!
    a.elem_store([1,1], -4)
    is_asserted_by {  (-4) == a.elem_fetch([1, 1]) }
    a.elem_store([1,1], UNDEF)
    is_asserted_by {  UNDEF == a.elem_fetch([1, 1]) }

    #
    a = CArray.int(3,3).seq!
    a.elem_store(4, -4)
    is_asserted_by {  (-4) == a.elem_fetch(4) }
    a.elem_store(4, UNDEF)
    is_asserted_by {  UNDEF == a.elem_fetch(4) }
  end

  example "elem_incr_decr" do
    #
    a = CArray.int(3,3).seq!
    a.elem_incr([1,1])
    is_asserted_by {  5 == a.elem_fetch([1, 1]) }
    a.elem_decr([1,1])
    is_asserted_by {  4 == a.elem_fetch([1, 1]) }

    #
    a = CArray.int(3,3).seq!
    a.elem_incr(4)
    is_asserted_by {  5 == a.elem_fetch(4) }
    a.elem_decr(4)
    is_asserted_by {  4 == a.elem_fetch(4) }
  end

  example "elem_incr_255" do
    #
    a = CArray.uint8(1) {255}
    a.elem_incr(0)
    is_asserted_by {  0 == a.elem_fetch(0) }

    #
    a = CArray.int8(1) {127}
    a.elem_incr(0)
    is_asserted_by {  (-128) == a.elem_fetch(0) }
  end

end
