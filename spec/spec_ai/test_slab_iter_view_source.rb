require "test/unit"
require "carray"
require "rbconfig"

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

  # A slab kept past the walk (the slab itself or `slab.dup`, which shares
  # its buffer) reads the last slab, not freed memory; `slab.copy` keeps
  # each one.  An object array's cells are also marked by the GC from
  # there, so the kept slab must not point into the walk's freed scratch.
  def test_slab_kept_past_the_walk
    f = CArray.float64(2, 3).seq
    [->(x) { x }, ->(x) { x.transpose }].each do |mk|
      src = mk.call(f)
      axis = src.ndim - 2
      kept = []; dups = []; copies = []
      src.each_slab(axis: axis) { |r| kept << r; dups << r.dup; copies << r.copy }
      1000.times { "x" * 50 }
      last = copies.last.to_a
      assert_equal [last] * copies.size, kept.map(&:to_a)
      assert_equal [last] * copies.size, dups.map(&:to_a)
      ref = []; src.copy.each_slab(axis: axis) { |r| ref << r.to_a }
      assert_equal ref, copies.map(&:to_a)
    end
    script = <<~'RUBY'
      require "carray"
      a = CArray.object(2, 3); 6.times { |i| a[i / 3, i % 3] = Rational(i, 7) }
      [a, a.transpose].each do |src|
        rows = []; src.each_slab(axis: 0) { |r| rows << r.dup }
        GC.start; 1000.times { "x" * 50 }; GC.start
        rows.each(&:to_a)
      end
      16.times { a.transpose.map_slab(axis: 1) { |x| x + 1 } ; GC.start }
    RUBY
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    assert system(RbConfig.ruby, *inc, "-e", script, err: File::NULL), "child ended with #{$?.inspect}"
  end
end
