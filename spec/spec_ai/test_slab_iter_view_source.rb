require "test/unit"
require "carray"

# each_slab over a view: the slab handed to the block reads the cells of
# that slab, and so does anything derived from it (dup, sort_copy, ...).
# Slabs of several axes are taken from every kind of source.

class TestSlabIterViewSource < Test::Unit::TestCase

  def base (masked: false)
    a = CArray.float64(2, 3, 4)
    a[] = CA_FLOAT64((0...24).map { |i| ((i * 7919) % 13).to_f })
    a[(a % 5).eq(1)] = UNDEF if masked
    a
  end

  def sources (a)
    b = base + 100
    {
      "entity"    => a,
      "transpose" => a.transpose(1, 0, 2),
      "block"     => a[nil, 0..2, 1..3],
      "grid"      => a[nil, CA_INT64([2, 0]), nil],
      "window"    => a.window(nil, nil, 0..3),
      "roll"      => a.roll(0, 1, 1),
      "lazy"      => a.lazy + 1,
      "fake"      => a.as_type(:float32),
      "meld"      => CArray.meld(a, b, axis: 0),
      "stack"     => CArray.stack([a, b], axis: 1),
    }
  end

  def slabs (src, axis)
    out = []
    src.each_slab(axis: axis) { |x| out << [x.to_a, x.dup.to_a, x.sort_copy.to_a] }
    out
  end

  def reference (src, axis)
    slabs(src.copy, axis)
  end

  def test_single_axis_slabs_and_their_views
    [false, true].each do |m|
      sources(base(masked: m)).each do |label, src|
        src.ndim.times do |ax|
          assert_equal reference(src, ax), slabs(src, ax),
                       "#{label} masked=#{m} axis #{ax}"
        end
      end
    end
  end

  def test_multi_axis_slabs_from_every_source
    [false, true].each do |m|
      sources(base(masked: m)).each do |label, src|
        n = src.ndim
        (0...n).to_a.combination(2).each do |axes|
          assert_equal reference(src, axes), slabs(src, axes),
                       "#{label} masked=#{m} axes #{axes}"
        end
      end
    end
  end

end
