require "test/unit"
require "carray"

# A generated kernel reads its source through the CArray pointer only.  When
# the dispatcher, or a C caller, hands it a view made for the call -- a
# common-type view of the array or the query, a flattened array -- that view
# has to stay reachable until the kernel returns, or a garbage collection run
# while its cells are read frees them.  GC.stress makes such a collection
# happen on every allocation, so a missing guard shows up deterministically.
class TestKernelDispatchGC < Test::Unit::TestCase

  def under_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  def test_linear_section_with_a_query_of_another_type
    r = CA_INT64((0...50).map { |i| i * 10 })
    q = CA_INT64((0...300).to_a)
    s = under_stress { r.linear_section(q) }
    assert_equal 10.0, s[100]
  end

  def test_bsearch_with_a_query_of_another_type
    r = CA_INT64((0...50).map { |i| i * 10 })
    q = CA_DOUBLE((0...300).map { |i| i * 1.0 })
    b = under_stress { r.bsearch(q) }
    assert_equal 30, b.count_not_masked
  end

  def test_order_of_a_flattened_array
    a = CA_INT32((0...400).to_a.reverse)
    o = under_stress { a.order }
    assert_equal (0...400).to_a.reverse, o.to_a
  end
end
