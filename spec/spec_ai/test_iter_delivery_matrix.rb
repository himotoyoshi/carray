# The kernel iterator hands a kernel the cells of a source, and on WRITE
# takes what the kernel wrote back to the root.  Whichever route it picks
# for a source, the kernel must receive the cells and mask flags of the
# view's materialised copy, in the view's row-major order, and a write must
# land on the root cells the view covers and nowhere else.
#
# The matrix is parents x views x masked/unmasked x four ways of walking
# (L1 whole, L2 whole, one slab axis, one contiguous fiber), read and
# write.  A whole walk may yield its cells as several row-major slabs; they
# are compared joined.  The expected answers are built without the iterator: the read
# from the view's copy, the write by storing the same values through the
# same view of an unmasked copy of the root.
#
# rake spec_ai, spec_ai_general and spec_ai_transfer run it with
# CARRAY_GENERAL_PATH unset, 1 and 2.  With 2 every source takes the
# transfer walk, so the three runs compare the iterator's other routes
# with that one.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_write", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_write"
rescue LoadError
  warn "Skipping test_iter_delivery_matrix: iter_write not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterDeliveryMatrix < Test::Unit::TestCase

  MODES = { 0 => "L1 whole", 1 => "L2 whole", 2 => "slab axis", 3 => "fiber" }

  # name => [root shape, root type, parent built on the root (rank 3)]
  PARENTS = {
    "entity"     => [[3, 4, 5], :float64, ->(r) { r }],
    "transpose"  => [[5, 4, 3], :float64, ->(r) { r.transpose }],
    "block"      => [[4, 6, 5], :float64, ->(r) { r[1..3, 1..4, nil] }],
    "step block" => [[3, 8, 5], :float64, ->(r) { r[nil, [0, 4, 2], nil] }],
    "reshape"    => [[60],      :float64, ->(r) { r.reshape(3, 4, 5) }],
    "grid"       => [[4, 5, 6], :float64,
                     ->(r) { r[CA_INT64([0, 2, 3]), CA_INT64([1, 0, 4, 2]), 0..4] }],
    "fake"       => [[3, 4, 5], :int32,   ->(r) { r.fake(:float64) }],
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
    shape, type, parent = PARENTS[parent_name]
    r = root(shape, type, masked)
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
  # iterator yields them: the outer axes row-major, the slab axis inside.
  def slab_addresses (shape, mode, axis)
    n = shape.inject(1, :*)
    return [(0...n).to_a] if mode < 2
    strides = row_major_strides(shape)
    outer   = (0...shape.size).reject { |k| k == axis }
    index_tuples(outer.map { |k| shape[k] }).map do |oi|
      base = outer.each_with_index.sum { |k, j| oi[j] * strides[k] }
      (0...shape[axis]).map { |i| base + i * strides[axis] }
    end
  end

  def walks (v)
    MODES.flat_map do |mode, name|
      (mode < 2 ? [0] : (0...v.ndim).to_a).map { |ax| [mode, ax, name] }
    end
  end

  def test_read_delivers_the_cells_of_the_copy
    cases = 0
    [false, true].each do |masked|
      PARENTS.each_key do |pn|
        READ_VIEWS.each do |vn, view|
          built = build(pn, view, masked) or next
          v = built[1]
          copy  = v.copy
          vals  = copy.value.to_a.flatten
          flags = copy.has_mask? ? copy.mask.to_a.flatten : []
          cells = vals.each_with_index.map { |x, i| flags[i] ? nil : x.to_f }
          walks(v).each do |mode, ax, name|
            exp = slab_addresses(v.shape, mode, ax).map { |s| s.map { |a| cells[a] } }
            got = CArray.iw_read_cells(v, mode, ax)
            got = [got.flatten(1)] if mode < 2
            assert_equal exp, got, "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax}"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

  def test_write_lands_where_a_store_through_the_view_lands
    cases = 0
    [false, true].each do |masked|
      PARENTS.each do |pn, (_, _, parent)|
        VIEWS.each do |vn, view|
          probe = build(pn, view, masked) or next
          walks(probe[1]).each do |mode, ax, name|
            r, v = build(pn, view, masked)
            vals = Array.new(v.elements)
            slab_addresses(v.shape, mode, ax).each_with_index do |s, k|
              s.each_with_index { |a, i| vals[a] = 1000.0 * (k + 1) + i }
            end
            ref   = r.value.copy
            ref_v = view.call(parent.call(ref))
            ref_v[] = CA_FLOAT64(vals).reshape(*v.shape)
            flags = r.has_mask? ? r.mask.to_a : nil

            CArray.iw_write_cells(v, mode, ax)

            label = "#{vn} of #{pn} masked=#{masked}: #{name} axis #{ax}"
            assert_equal ref.to_a, r.value.to_a, label
            assert_equal flags, (r.has_mask? ? r.mask.to_a : nil), "#{label} mask"
            cases += 1
          end
        end
      end
    end
    assert_operator cases, :>=, 1000
  end

end
