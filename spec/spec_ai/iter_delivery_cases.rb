# The cases the kernel iterator's delivery tests walk: parents x views, and
# the four ways of walking (L1 whole, one slab axis, one contiguous fiber,
# two slab axes).  Shared by test_iter_delivery_matrix.rb (the values a
# kernel receives and writes) and test_iter_delivery_detectors.rb (what a
# walk must not leave behind).

module IterDeliveryCases

  MODES = { 0 => "L1 whole", 2 => "slab axis", 3 => "fiber",
            4 => "two slab axes" }

  # name => [root shape, root type, parent built on the root (rank 3),
  #          and optionally a value added to every cell of the root]
  PARENTS = {
    "entity"     => [[3, 4, 5], :float64, ->(r) { r }],
    "transpose"  => [[5, 4, 3], :float64, ->(r) { r.transpose }],
    "block"      => [[4, 6, 5], :float64, ->(r) { r[1..3, 1..4, nil] }],
    "step block" => [[3, 8, 5], :float64, ->(r) { r[nil, [0, 4, 2], nil] }],
    "reshape"    => [[60],      :float64, ->(r) { r.reshape(3, 4, 5) }],
    "grid"       => [[4, 5, 6], :float64,
                     ->(r) { r[CA_INT64([0, 2, 3]), CA_INT64([1, 0, 4, 2]), 0..4] }],
    "fake"       => [[3, 4, 5], :int32,   ->(r) { r.fake(:float64) }],
    # A conversion that does not bring every value back: an int64 above
    # 2**53 read as float64 is rounded, so a cell sent back that the
    # kernel did not write would change.
    "lossy fake" => [[3, 4, 5], :int64,   ->(r) { r.fake(:float64) }, 2**53 + 1],
    "swap_bytes" => [[3, 4, 5], :float64, ->(r) { r.swap_bytes.swap_bytes }],
    "stack"      => [[3, 4, 5], :float64,
                     ->(r) { CArray.stack((0..2).map { |i| r[i, nil, nil] }) }],
    "meld"       => [[3, 4, 5], :float64,
                     ->(r) { CArray.meld(r[0..0, nil, nil], r[1..2, nil, nil], axis: 0) }],
    "roll"       => [[3, 4, 5], :float64, ->(r) { r.roll(1, 2, 3) }],
  }

  # Views over a rank-3 parent of shape (3, 4, 5).
  VIEWS = {
    "itself"      => ->(p) { p },
    "row block"   => ->(p) { p[1..2, nil, nil] },
    "inner block" => ->(p) { p[nil, 1..2, 1..3] },
    "stepped"     => ->(p) { p[nil, [0, 2, 2], [4, 3, -2]] },
    "transpose"   => ->(p) { p.transpose },
    "axis swap"   => ->(p) { p.transpose(0, 2, 1) },
    "reshape"     => ->(p) { p.reshape(6, 10) },
    "grid"        => ->(p) { p[CA_INT64([2, 0]), nil, CA_INT64([1, 3, 4])] },
    "grid inner"  => ->(p) { p[nil, nil, CA_INT64([4, 0, 2])] },
    "select axis" => ->(p) { p[CA_BOOLEAN([1, 0, 1]), nil, nil] },
    "window"      => ->(p) { p.window(0..1, 1..3, 2..4) },
    "shift"       => ->(p) { p.shift(1, 0, -1) },
    "roll"        => ->(p) { p.roll(1, 1, 0) },
    # Shows root row 0 twice: what the kernel writes into one copy must
    # not be overwritten by the copy it left alone.
    "repeated row" => ->(p) { p[CA_INT64([0, 0, 2]), nil, nil] },
  }

  # Read only: a tile repeats cells, a lazy expression has no cells to
  # write.
  READ_VIEWS = VIEWS.merge(
    "tile" => ->(p) { p.tile(1, 2, 1) },
    "lazy" => ->(p) { (p.lazy * 2) + 1 },
  )

  def root (shape, type, masked)
    n = shape.inject(:*)
    r = CArray.new(type, shape)
    r[] = CA_FLOAT64((0...n).map { |i| ((i * 37) % 101).to_f }).to_type(type)
    r[(r % 11).eq(2) | (r % 11).eq(9)] = UNDEF if masked
    r
  end

  # [root, view], or nil when the view does not apply to this parent.
  def build (parent_name, view, masked)
    shape, type, parent, offset = PARENTS[parent_name]
    r = root(shape, type, masked)
    r.add!(offset) if offset
    [r, view.call(parent.call(r))]
  rescue ArgumentError, IndexError, TypeError, RangeError
    nil
  end

  def row_major_strides (shape)
    s = 1
    shape.reverse.map { |d| t = s; s *= d; t }.reverse
  end

  def index_tuples (dims)
    dims.inject([[]]) { |acc, d| acc.flat_map { |t| (0...d).map { |i| t + [i] } } }
  end

  # Row-major addresses of the cells of each slab, in the order the
  # iterator yields them: the outer axes row-major, the slab axes inside
  # (row-major too when there are two: `axis` and the last axis).
  def slab_addresses (shape, mode, axis)
    n = shape.inject(1, :*)
    return [(0...n).to_a] if mode == 0
    slab    = mode == 4 ? [axis, shape.size - 1] : [axis]
    strides = row_major_strides(shape)
    outer   = (0...shape.size).reject { |k| slab.include?(k) }
    index_tuples(outer.map { |k| shape[k] }).map do |oi|
      base = outer.each_with_index.sum { |k, j| oi[j] * strides[k] }
      index_tuples(slab.map { |k| shape[k] }).map do |si|
        base + slab.each_with_index.sum { |k, j| si[j] * strides[k] }
      end
    end
  end

  def walks (v)
    MODES.flat_map do |mode, name|
      axes = case mode
             when 0    then [0]
             when 4    then (0...v.ndim - 1).to_a
             else           (0...v.ndim).to_a
             end
      axes.map { |ax| [mode, ax, name] }
    end
  end

  # Every case: yields parent name, view name, root and view.
  def each_case (views, masked)
    PARENTS.each_key do |pn|
      views.each do |vn, view|
        built = build(pn, view, masked) or next
        yield pn, vn, *built
      end
    end
  end

end
