require "test/unit"
require "carray"

# A Ruby Array has no data type of its own, so it does not stand in for a
# CArray where an array with a data type is expected.  It is refused with
# the method's name and a hint to write the type; an object array still
# takes it as one value.
class TestArrayNotACArray < Test::Unit::TestCase

  def assert_refused (name, &block)
    e = assert_raise(TypeError, &block)
    assert_match(/\A#{Regexp.escape(name)}: a Ruby Array /, e.message)
    assert_match(/make it a CArray/, e.message)
    e
  end

  def test_result_type
    e = assert_refused("result_type") { CArray.result_type(CA_INT32([1]), [1, 2]) }
    assert_match(/CA_INT64\(ary\) or CA_FLOAT64\(ary\)/, e.message)
    assert_refused("result_type") { CArray.result_type([1.5]) }
    e = assert_refused("result_type") { CArray.result_type(CA_BOOLEAN([true]), [true]) }
    assert_match(/CA_BOOLEAN\(ary\)/, e.message)
    assert_equal :object, CArray.result_type(CA_OBJECT([1]), [1])
    assert_equal :float64, CArray.result_type(CA_INT32([1]), 1.5)
  end

  def test_is_in_keeps_an_array_element_as_a_value
    assert_equal [false, false, true], CA_INT32([1, 2, 3]).is_in([[1, 2], 3]).to_a
  end

  def test_align_addr
    assert_refused("align_addr") { CArray.align_addr([1, 2], [2.0, 3]) }
    assert_refused("align_addr") { CArray.align_addr(CA_INT32([1, 2]), [2, 3]) }
    common, = CArray.align_addr(CA_INT32([1, 2]), CA_FLOAT64([2.0, 3]))
    assert_equal [1.0, 2.0, 3.0], common.to_a
    assert_refused("align_nearest_addr") { CArray.align_nearest_addr([1.0, 2.0]) }
    assert_refused("align_nearest_addr") {
      CArray.align_nearest_addr(CA_FLOAT64([1, 2]), grid: [1, 2])
    }
  end

  def test_broadcast
    a = CA_INT32([1, 2, 3])
    assert_refused("broadcast") { CArray.broadcast(a, [1, 2, 3]) }
    assert_equal [a.class, Integer], CArray.broadcast(a, 1).map(&:class)
  end

  def test_camath_refuses_an_array_in_either_argument
    f = CA_FLOAT32([1, 1])
    %i[atan2 hypot copysign logaddexp nextafter fmod].each do |m|
      assert_refused(m.to_s) { CAMath.send(m, [1.0, 2.0], f) }
      assert_raise(TypeError) { CAMath.send(m, f, [1.0, 2.0]) }
    end
    assert_refused("expm1") { CAMath.expm1([1.0]) }
    assert_refused("log1p") { CAMath.log1p([1.0]) }
    assert_equal "float32", CAMath.atan2(1.0, f).data_type_name
  end

  def test_string_faces_refuse_an_array_in_eq_and_ne
    s = CArray.string(%w[a b a])
    [s, s.to_fixlen_string, s.to_const_string].each do |x|
      e = assert_refused("eq") { x.eq(%w[a b a]) }
      assert_match(/CArray\.string\(ary\)/, e.message)
      assert_refused("ne") { x.ne(%w[a b a]) }
      assert_equal [true, false, true], x.eq("a").to_a
      assert_equal [true, true, false], x.eq(CArray.string(%w[a b b])).to_a
    end
  end


  # Where one value of a cell is read, a Ruby Array is not one value.
  def test_a_value_of_a_cell_is_not_an_array
    i = CA_INT32([1, 2, 3])
    f = CA_FLOAT64([1.0, 2.0, 3.0])
    { "bsearch" => -> { i.bsearch([1, 2]) },
      "search" => -> { i.search([1, 2]) },
      "search_nearest" => -> { f.search_nearest([1.0]) },
      "linear_section" => -> { f.linear_section([1.5]) },
      "wsum" => -> { i.wsum([1, 1, 1]) },
      "count" => -> { i.count([1]) },
      "fill" => -> { i.dup.fill([1]) },
      "strip_mask" => -> { i.strip_mask([1]) },
      "sum" => -> { i.sum(fill_value: [1]) },
      "shift" => -> { i.shift(1, fill_value: [1]) },
      "[]=" => -> { i.dup[0] = [1] } }.each do |name, f|
      e = assert_raise(TypeError, name) { f.call }
      assert_match(/\A#{Regexp.escape(name)}: a Ruby Array is not a value of (an integer|a float) cell\z/, e.message)
    end
    e = assert_raise(TypeError) { CA_BOOLEAN([true]).fill([true]) }
    assert_match(/a boolean cell/, e.message)
    o = CA_OBJECT([1, 2])
    o.fill([1])
    assert_equal [[1], [1]], o.to_a
    assert_equal 1, CA_OBJECT([[1], 2]).count([1])
  end

  def test_arrays_to_join_and_to_search
    i = CA_INT32([1, 2])
    assert_refused("concatenate") { CArray.concatenate([i, [1, 2]]) }
    assert_refused("stack") { CArray.stack([i, [1, 2]]) }
    assert_refused("meld") { CArray.meld([i, [1, 2]]) }
    assert_refused("promote_list") { CArray.promote_list([i, [1, 2]]) }
    assert_refused("paste") { CArray.int32(3, 3).paste([0, 0], [1, 2]) }
    assert_refused("locate_nearest_addr") { CA_FLOAT64([1, 2]).locate_nearest_addr([1.0]) }
  end

  def test_iterator_kernels_and_weights
    i = CA_INT32([1, 2, 3])
    assert_refused("correlate") { i.windows(-1..1).correlate([1, 1, 1]) }
    assert_refused("convolve") { i.windows(-1..1).convolve([1, 1, 1]) }
    assert_refused("wsum/wmean") { i.windows(-1..1).wsum([1, 1, 1]) }
    assert_refused("wsum/wmean") { CArray.int32(3, 3).seq!.blocks(1, 3).wsum([1, 1, 1]) }
    cat = CA_INT32([0, 1, 0]).categorize
    assert_refused("wsum/wmean") { i.group_by_category(cat).wsum([1, 1, 1]) }
  end


  # Weights pair with the cells one to one, so a Ruby Array is refused;
  # edges are a list of positions and are taken as a Ruby Array.
  def test_histogram_weights_but_not_edges
    x = CA_FLOAT64([0.5, 1.5, 1.7])
    assert_refused("histogram") { x.histogram1d(edges: [0, 1, 2], weights: [3, 1, 0.5]) }
    assert_kind_of CArray::Histogram,
                   x.histogram1d(edges: [0, 1, 2], weights: CA_FLOAT64([3, 1, 0.5]))
    assert_kind_of CArray::Histogram, x.histogram1d(edges: [0, 1, 2])
    assert_equal 3, x.bin_to([0, 1, 2]).elements
    assert_refused("bincount_nd") {
      CArray.int32(3, 2) { 0 }.bincount_nd(lengths: [2, 2], weights: [1.0, 2.0, 3.0])
    }
    l = CA_INT32([0, 1, 1])
    assert_refused("bincount") { l.bincount(weights: [1.0, 2.0, 3.0]) }
    assert_equal [1.0, 5.0], l.bincount(weights: CA_FLOAT64([1.0, 2.0, 3.0])).to_a
  end


  def test_camath_lgamma_and_coordinate_conversions
    f = CA_FLOAT64([1.0])
    assert_refused("lgamma") { CAMath.lgamma([1.5]) }
    assert_equal "float64", CAMath.lgamma(CA_FLOAT64([1.5])).data_type_name
    assert_refused("spherical_to_xyz") { CAMath.spherical_to_xyz([1.0], f, f) }
    assert_refused("spherical_to_xyz") { CAMath.spherical_to_xyz(f, f, [0.0]) }
    assert_refused("xyz_to_spherical") { CAMath.xyz_to_spherical(f, [0.0], f) }
    assert_equal 3, CAMath.spherical_to_xyz(f, f, f).size
  end

end
