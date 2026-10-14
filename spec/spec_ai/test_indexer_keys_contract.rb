require "test/unit"
require "carray"

# A key means the same cells whichever view the indexer builds for it: a
# CArray among the keys (grid / CASelectAxis) reads every other key as a
# block reference does.  And a store writes exactly the cells the same
# index reads.
class TestIndexerKeysContract < Test::Unit::TestCase

  def a34
    CArray.int32(3, 4).seq
  end

  # Rows picked by an index array, columns by `col`, should read as the
  # block reference of each row does.
  def assert_grid_reads_as_block (col)
    a = a34
    i = CA_INT32([2, 0])
    assert_equal [a[2, col].to_a, a[0, col].to_a], a[i, col].to_a, col.inspect
  end

  # ---------- keys beside a CArray ----------

  def test_ranges_beside_an_index_array_read_as_a_block_does
    [-1..1, 2..1, 1.., ..2, -2...0, 1...3, [1, 2], [0, 2, 2], (3..0).step(-2),
     0.step(3, 2), [nil, 2]].each do |col|
      assert_grid_reads_as_block(col)
    end
  end

  def test_ranges_beside_a_boolean_on_axis_0
    a = a34
    b = CA_BOOLEAN([1, 0, 1])
    [3..1, 1..2, -1..0, [nil, 2]].each do |col|
      assert_equal [a[0, col].to_a, a[2, col].to_a], a[b, col].to_a, col.inspect
    end
    assert_equal [2, 0], a[b, 2...2].shape
  end

  def test_an_integer_key_beside_a_carray_drops_its_axis
    a = a34
    assert_equal [9, 1], a[CA_INT32([2, 0]), 1].to_a
    assert_equal [4, 6], a[1, CA_INT32([0, 2])].to_a
    assert_equal [1, 9], a[CA_BOOLEAN([1, 0, 1]), 1].to_a
  end

  def test_a_boolean_selector_must_be_as_long_as_its_axis
    assert_raise(ArgumentError) { a34[nil, CA_BOOLEAN([1, 0])] }
    assert_raise(ArgumentError) { a34[1, CA_BOOLEAN([1, 0, 0, 0, 0, 0])] }
  end

  def test_keys_that_are_not_positions_are_refused_beside_a_carray
    i = CA_INT32([2, 0])
    ["x", "2", 1.5, :foo, true, Object.new].each do |k|
      assert_raise(IndexError, k.inspect) { a34[i, k] }
    end
  end

  def test_rubber_beside_a_carray
    a = a34
    i = CA_INT32([2, 0])
    assert_equal a[nil, i].to_a, a[false, i].to_a
    assert_equal a[i, nil].to_a, a[i, :~].to_a
    b = CArray.int32(2, 3, 4).seq
    assert_equal b[nil, nil, CA_INT32([1])].to_a, b[false, CA_INT32([1])].to_a
  end

  def test_newaxis_beside_a_carray
    b = CArray.int32(4).seq
    assert_equal [2, 2, 1], b[CA_INT32([[0, 1], [2, 3]]), :_].shape
    assert_equal [2, 1], a34[CA_INT32([1, 2]), 1, :_].shape
  end

  def test_a_store_through_a_grid_writes_the_cells_it_reads
    a = a34
    a[CA_INT32([2, 0]), -1..1] = CArray.int32(2, 3) { -1 }
    assert_equal [[0, -1, -1, -1], [4, 5, 6, 7], [8, -1, -1, -1]], a.to_a
  end

  # ---------- step and direction ----------

  def test_step_says_the_direction
    b = CArray.int32(5).seq
    assert_equal [3, 2, 1, 0], b[3.step(by: -1)].to_a
    assert_equal [4, 2, 0],    b[4.step(by: -2)].to_a
    assert_equal [],           b[(0..4).step(-1)].to_a
    assert_equal [],           b[(4..0).step(1)].to_a
    assert_equal [],           b[2.step(4, -1)].to_a
    assert_equal [],           b[[0..4, -1]].to_a
    assert_equal [0],          b[[nil, -1]].to_a   # from the first cell
    assert_equal [0, 2, 4],    b[[nil, 2]].to_a
    assert_equal [4, 3, 2, 1], b[(4...0).step(-1)].to_a
  end

  def test_a_float_with_a_fraction_in_a_range_an_array_form_or_a_step_is_refused
    b = CArray.int32(5).seq
    [1.5..3, 1..2.5, [1.5, 2], [1, 2.9], 0.step(4, 1.5)].each do |k|
      assert_raise(IndexError, k.inspect) { b[k] }
    end
    # a Float holding an integer (a count from sum) is that integer
    assert_equal [1, 2, 3], b[1.0..3].to_a
    assert_equal [0, 2, 4], b[(0..4).step(2.0)].to_a
    assert_equal [1, 2],    b[[1, 2.0]].to_a
  end

  def test_a_scalar_key_takes_a_float_that_holds_an_integer
    b = CArray.int32(5).seq
    assert_equal 2, b[2.0]
    assert_equal 4, b[-1.0]
    b[2.0] = 9
    assert_equal [0, 1, 9, 3, 4], b.to_a

    a = a34
    assert_equal 6, a[1.0, 2.0]
    assert_equal 6, a[1, 2.0]
    assert_equal 7, a[7.0]            # address
    assert_equal 11, a[-1.0]
    assert_equal [4, 5], a[1.0, 0..1].to_a
    a[7.0] = 70
    a[0.0, 0.0] = 50
    assert_equal [50, 70], [a[0, 0], a[1, 3]]

    # beside a CArray (grid / CASelectAxis)
    a = a34
    assert_equal a[CA_INT32([2, 0]), 1].to_a, a[CA_INT32([2, 0]), 1.0].to_a
    sel = CA_BOOLEAN([true, false, true])
    assert_equal a[sel, 3].to_a, a[sel, 3.0].to_a
  end

  def test_a_scalar_key_refuses_a_float_that_is_not_an_integer
    b = CArray.int32(5)
    a = a34
    [1.5, -0.5, Float::NAN, Float::INFINITY, -Float::INFINITY, 1e19, -1e30].each do |k|
      assert_raise(IndexError, k.inspect) { b[k] }
      assert_raise(IndexError, k.inspect) { b[k] = 1 }
      assert_raise(IndexError, k.inspect) { a[k] }        # address
      assert_raise(IndexError, k.inspect) { a[k] = 1 }
      assert_raise(IndexError, k.inspect) { a[1, k] }
      assert_raise(IndexError, k.inspect) { a[CA_INT32([0]), k] }
    end
    assert_raise(IndexError) { b[5.0] }
    assert_raise(IndexError) { a[12.0] }
    # a Float array is not an index array
    assert_raise(IndexError) { b[CA_FLOAT64([1.0])] }
  end

  # Positions are int64 (ca_size_t), and an axis of a view that holds no
  # memory can be longer than a Fixnum reaches.
  def huge
    CArray.uint8(1) { 7 }.broadcast_to(2**62 + 10)
  end

  def test_an_integer_that_fits_int64_is_a_position_even_as_a_bignum
    v = huge
    assert_equal 7, v[2**62 + 5]
    assert_equal 7, v[-(2**62)]                 # from the end
    assert_equal 7, v[2**62 + 9]
    assert_equal [7, 7, 7], v[(2**62)..(2**62 + 2)].to_a
    assert_equal [7, 7], v[[2**62, 2]].to_a
    assert_raise(IndexError) { v[2**62 + 10] }  # past the end, by the usual check
    assert_raise(IndexError) { v[-(2**62) - 11] }

    w = CArray.uint8(1, 1) { 7 }.broadcast_to(2, 2**61 + 3)
    assert_equal 7, w[2**62 + 1]                # address
    assert_equal 7, w[1, 2**61 + 2]
    assert_raise(IndexError) { w[2**62 + 6] }

  end

  def test_an_integer_past_int64_is_out_of_range
    b = CArray.int32(4)
    [2**63, -(2**63) - 1, 2**70, -(2**70), 0..2**70].each do |k|
      assert_raise(IndexError, k.inspect) { b[k] }
      assert_raise(IndexError, k.inspect) { b[k] = 1 }
    end
    assert_raise(IndexError) { CArray.int32(2, 2)[2**70] }
    assert_raise(IndexError) { huge[2**63] }
  end

  def test_a_step_is_its_value_and_one_past_int64_reaches_one_cell
    b = CArray.int32(5).seq
    assert_equal [0], b[(0..4).step(2**62)].to_a
    assert_equal [0], b[(0..4).step(2**70)].to_a
    assert_equal [4], b[(4..0).step(-(2**70))].to_a
    assert_equal [2], b[(2..0).step(-2**63)].to_a
    v = huge
    assert_equal [7, 7], v[(0..(2**62 + 9)).step(2**62 + 1)].to_a
    assert_equal [7], v[(0..(2**62 + 9)).step(2**63)].to_a
  end

  # A Float with no fraction is a position only while it is exact: past 2**53
  # it cannot tell neighbouring integers apart.
  def test_a_float_key_is_a_position_only_up_to_2_53
    v = huge
    assert_equal 7, v[2.0**53]
    assert_equal 7, v[-(2.0**53)]
    assert_equal 7, v[2**53 + 2]                # the Integer is fine
    [2.0**53 + 2, -(2.0**53) - 2, 2.0**62, 1e19].each do |k|
      assert_raise(IndexError, k.inspect) { v[k] }
      assert_raise(IndexError, k.inspect) { v[0..k] }
      assert_raise(IndexError, k.inspect) { v[(0..9).step(k)] }
    end
    err = assert_raise(IndexError) { v[2.0**53 + 2] }
    assert_match(/invalid for the index/, err.message)
  end

  def test_ranges_on_an_axis_of_length_zero
    z = CArray.int32(0)
    assert_equal [0], z[0..-1].shape
    assert_equal [0], z[..-1].shape
    assert_equal [0], CArray.int32(0, 3)[0..-1, 1].shape
    assert_raise(IndexError) { z[1..-1] }
  end

  # ---------- the method-call form ----------

  def test_method_call_store_writes_only_the_cells_it_picks
    f = CA_FLOAT64([1.5, 2.5, 3.5])
    v = f.fake(:int32)
    v[:eq, 2] = 9
    assert_equal [1.5, 9.0, 3.5], f.to_a
  end

  def test_method_call_arguments_are_the_methods
    x = CArray.int32(4).seq
    def x.pick (*args)
      CArray.boolean(4) { |k| k > 1 }
    end
    assert_equal [2, 3], x[:pick, :>].to_a
    assert_equal [2, 3], x[:pick, 3, :_].to_a
  end

  # ---------- the mapping fast path ----------

  def test_mapping_checks_its_indices_when_made_and_keeps_them
    a = CArray.int32(2, 3).seq
    idx = CArray.int64(2, 3).seq
    idx[0, 0] = 9
    assert_raise(IndexError) { a[idx] }
    idx2 = CArray.int64(2, 3).seq
    r = a[idx2]
    idx2[0, 0] = 5
    assert_equal [[0, 1, 2], [3, 4, 5]], r.to_a
  end

  # ---------- boolean selectors ----------

  def test_a_boolean_selector_states_its_shape
    a = a34
    assert_raise(ArgumentError) { a[CArray.boolean(4, 3) { 1 }] }
    assert_equal [6, 7, 8, 9, 10, 11], a[a.gt(5)].to_a
    assert_equal [3], a[CArray.boolean(12) { |k| k == 3 }].to_a
  end

  # ---------- the removed attribute form ----------

  def test_an_at_string_is_a_member_name
    assert_raise(IndexError) { a34["@x"] }
    assert_raise(IndexError) { a34["@x"] = 1 }
  end

  # ---------- stores ----------

  def test_a_ruby_array_store_clears_the_mask_of_the_cells
    a = CA_INT32([1, 2, 3])
    a[1] = UNDEF
    a[] = [7, 8, 9]
    assert_equal [7, 8, 9], a.to_a
    b = CA_INT32([1, 2, 3])
    b[1] = UNDEF
    b[] = [7, UNDEF, 9]
    assert_equal [7, UNDEF, 9], b.to_a
  end

  def test_a_store_into_no_cells_checks_the_value
    a = CArray.int32(4).seq
    assert_raise(ArgumentError) { a[2...2] = [1, 2, 3] }
    assert_raise(ArgumentError) { a[2...2] = CA_INT32([1, 2, 3]) }
    assert_raise(ArgumentError) { a[2...2] = "x" }
    assert_raise(ArgumentError) { a[a.gt(10)] = [1, 2, 3] }
    a[2...2] = []
    a[2...2] = 5
    a[2...2] = UNDEF
    assert_equal [0, 1, 2, 3], a.to_a
  end

end
