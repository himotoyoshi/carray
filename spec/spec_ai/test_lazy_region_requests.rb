require "test/unit"
require "carray"

# The element-wise lazy views answer a region request (a stepped or
# reversed slice) and an address list (a selection) by pulling each operand
# over the same cells and running the kernel once.  Every answer must equal
# the eager result at those cells.
class TestLazyRegionRequests < Test::Unit::TestCase

  N = 24

  # [name, lazy expression, eager expression]
  def cases
    i16 = CArray.int16(N).seq
    f   = CArray.float64(N) { |i| i * 0.25 - 2.0 }
    g   = CArray.float64(N) { |i| (i % 5) - 2.0 }
    m   = f.copy
    m[3] = UNDEF
    m[10] = UNDEF
    z   = CArray.int32(N) { |i| i % 4 }
    k   = CArray.int32(N) { |i| i * 3 - 20 }
    [
      ["monop through a cast", i16.lazy.sinh,           i16.sinh],
      ["monop",                f.lazy.abs,              f.abs],
      ["binop",                f.lazy * g,              f * g],
      ["binop with a scalar",  f.lazy - 1.5,            f - 1.5],
      ["trapping binop",       k.lazy / (z + 1),        k / (z + 1)],
      ["masked binop",         m.lazy + g,              m + g],
      ["moncmp",               f.lazy.is_nan,           f.is_nan],
      ["bincmp",               f.lazy > g,              f > g],
      ["triop",                f.lazy.fma(g, 1.0),      f.fma(g, 1.0)],
    ]
  end

  def assert_same_cells (label, lazy_view, eager_view)
    assert_equal eager_view.to_a, lazy_view.to_a, label
    assert_equal eager_view.is_masked.to_a, lazy_view.is_masked.to_a, label
  end

  def test_stepped_slice
    cases.each do |name, lazy, eager|
      assert_same_cells "#{name}: step 2", lazy[(0...N).step(2)], eager[(0...N).step(2)]
      assert_same_cells "#{name}: step 3 from 1", lazy[(1...N).step(3)], eager[(1...N).step(3)]
    end
  end

  def test_reversed_slice
    cases.each do |name, lazy, eager|
      assert_same_cells "#{name}: reversed", lazy[-1..0], eager[-1..0]
    end
  end

  def test_address_list
    idx = CA_INT64([5, 0, 23, 5, 11, 3])
    cases.each do |name, lazy, eager|
      assert_same_cells "#{name}: indices", lazy[idx], eager[idx]
    end
  end

  def test_rows_of_a_reshaped_root
    cases.each do |name, lazy, eager|
      lv = lazy.reshape(4, 6)
      ev = eager.reshape(4, 6)
      rows = CA_INT64([2, 0])
      assert_same_cells "#{name}: rows", lv[rows, nil], ev[rows, nil]
      assert_same_cells "#{name}: shifted", lv.shift(1, 1), ev.shift(1, 1)
    end
  end
end
