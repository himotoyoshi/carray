require "test/unit"
require "carray"

# A view of a frozen array is read-only, not frozen: building the view may
# still set it up after its parent is attached, and writes through it are
# refused by the read-only check that walks the parent chain.
class TestFrozenViews < Test::Unit::TestCase

  def frozen_array(data_type = :float64)
    a = CArray.new(data_type, [3, 4])
    if data_type == :object
      a[] = CA_OBJECT((0...12).to_a).reshape(3, 4)
    else
      a.seq!
    end
    a.freeze
  end

  def assert_read_only_view(v)
    assert_predicate v, :read_only?
    assert_not_predicate v, :frozen?
    assert_raise(RuntimeError) { v[] = 0 }
  end

  BUILDERS = {
    "block"       => ->(a) { a[0..1, nil] },
    "transpose"   => ->(a) { a.transpose },
    "select_axis" => ->(a) { a[CA_BOOLEAN([1, 0, 1]), nil] },
    "boolean"     => ->(a) { a[a.gt(3)] },
    "sort"        => ->(a) { a.sort },
    "sort axis"   => ->(a) { a.sort(axis: 1) },
    "lazy scalar" => ->(a) { a.lazy * 2 },
    "lazy binop"  => ->(a) { a.lazy + a },
    "lazy cmp"    => ->(a) { a.lazy.lt(a) },
    "lazy triop"  => ->(a) { a.lazy.fma(a, a) },
    "lazy view"   => ->(a) { a.lazy[0..1, nil] },
    "lazy sort"   => ->(a) { (a.lazy * 2).sort(axis: 1) },
  }

  %i[float64 object].each do |dt|
    BUILDERS.each do |name, build|
      define_method("test_#{dt}_#{name.tr(' ', '_')}") do
        a = frozen_array(dt)
        v = build.(a)
        expect = build.(a.copy)
        assert_equal expect.to_a, v.to_a
        assert_raise(RuntimeError) { v[] = 0 }
        assert_equal frozen_array(dt).to_a, a.to_a
      end
    end
  end

  def test_view_is_read_only_not_frozen
    assert_read_only_view frozen_array[0..1, nil]
  end

  def test_object_median_and_partition_along_an_axis
    a = frozen_array(:object)
    assert_equal a.copy.median(axis: 1).to_a, a.median(axis: 1).to_a
    assert_equal a.copy.partition_copy(1, axis: 1).to_a,
                 a.partition_copy(1, axis: 1).to_a
  end

  def test_real_and_imag_of_frozen_complex
    c = CArray.cmplx128(3).seq!.freeze
    assert_equal [0.0, 1.0, 2.0], c.real.to_a
    assert_equal [0.0, 0.0, 0.0], c.imag.to_a
    assert_raise(RuntimeError) { c.real[0] = 9 }
  end

  def test_mask_of_frozen_array_is_read_only
    a = CArray.float64(3).seq!
    a[0] = UNDEF
    a.freeze
    m = a.mask
    assert_predicate m, :read_only?
    assert_raise(RuntimeError) { m[1] = true }
  end

  def test_views_of_frozen_faces
    t = CArray.int64(4) { |i| i }.time(unit: :s).freeze
    assert_equal t.copy[0..1].to_a, t[0..1].to_a
    assert_equal t.copy.sort.to_a, t.sort.to_a
    assert_equal t.copy[CA_BOOLEAN([1, 0, 1, 1])].to_a, t[CA_BOOLEAN([1, 0, 1, 1])].to_a
    assert_raise(RuntimeError) { t[0..1][0] = t[3] }
  end
end
