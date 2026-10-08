require "test/unit"
require "carray"

# A fiber along a non-innermost axis is handed to the kernel as a
# contiguous run of cells and of mask flags.  Every walk path keeps that
# promise, including the ones that read a stack's parents directly and the
# ones that gather a descriptor view slab by slab.  The answers along any
# axis are those of the materialised copy.

class TestIterFiberContigPaths < Test::Unit::TestCase

  OPS = [
    [:sort_copy,       ->(a, ax) { a.sort_copy(axis: ax) }],
    [:median,          ->(a, ax) { a.median(axis: ax) }],
    [:percentile,      ->(a, ax) { a.percentile(30, axis: ax) }],
    [:is_mode,         ->(a, ax) { a.is_mode(axis: ax) }],
    [:mask_duplicates, ->(a, ax) { a.mask_duplicates(axis: ax) }],
  ]

  def base (*shape, masked: false)
    n = shape.inject(:*)
    a = CArray.float64(*shape)
    a[] = CA_FLOAT64((0...n).map { |i| ((i * 7919) % 13).to_f })
    if masked
      a[(a % 5).eq(1)] = UNDEF
    end
    a
  end

  def assert_same_as_copy (view, label)
    view.ndim.times do |ax|
      OPS.each do |name, op|
        got = op.(view, ax)
        exp = op.(view.copy, ax)
        assert_equal exp.to_a, got.to_a, "#{label} #{name}(axis: #{ax})"
      end
    end
  end

  def test_stack_inner_axes
    [false, true].each do |m|
      x = base(2, 3, 4, masked: m)
      y = base(2, 3, 4, masked: false) + 100
      [0, 1, 2, 3].each do |k|
        assert_same_as_copy CArray.stack([x, y], axis: k), "stack(axis: #{k}) masked=#{m}"
      end
    end
  end

  def test_stack_two_by_three
    s = CArray.stack([CA_FLOAT64([[5,1,4],[2,9,0]]), CA_FLOAT64([[7,3,8],[6,2,1]])], axis: 0)
    assert_equal [[3.5, 5.0, 2.0], [6.5, 2.5, 4.5]], s.median(axis: 1).to_a
  end

  def test_masked_descriptor_views
    a = base(2, 3, 4, masked: true)
    views = {
      "grid middle"        => a[nil, CA_INT64([0, 2]), nil],
      "grid outer"         => a[CA_INT64([1, 0]), nil, nil],
      "transposed grid"    => a.transpose[CA_INT64([0, 2, 3]), nil, nil],
      "grid of two axes"   => a[CA_INT64([1, 0]), nil, CA_INT64([3, 1, 0])],
    }
    views.each { |label, v| assert_same_as_copy v, label }
  end

end
