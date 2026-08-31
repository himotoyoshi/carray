# An xfer_stride request is expressed over the view's linear ADDRESSES
# (carray.h, xfer_stride slot), so request axis k need not be the view's
# axis k: a caller may hand over a transposed region -- counts / strides in
# column-major order, the destination buffer packed in that order.  A
# Fortran-LAPACK backend (carray-linalg-accelerate) gathers exactly like
# this.
#
# The trap this pins: on a view with a degenerate axis -- (n, 1), the shape
# a promoted column vector takes -- both axes have the same native step, so
# a transposed request divides cleanly by the axis-k step and looks
# axis-aligned.  A structural path that then composes the n-cell walk onto
# the length-1 axis follows that axis' parent stride (0 for a promoted
# axis), delivering the first cell n times, silently.  Observed as
# `solve(a, b)` returning [b[0], b[0], b[0]] for a (n, 1) right-hand side.
#
# Every view class with a structural xfer_stride path is asked the same
# question here: deliver a column-major region, and match the cells the
# view itself reports.

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"

# A value-producing backing with copy_block: the CAObject slot hands the
# request to Ruby as a per-axis (starts, counts, steps) triple, and Ruby
# composes it per axis -- so a transposed request must not be handed over
# that way.
class TransposedRequestSource < CAObject
  def initialize (n, m)
    @n = n
    @m = m
    super(CA_FLOAT64, [n, m])
  end

  def value_at (addr)
    (addr / @m + 1) * 10.0 + (addr % @m)
  end

  def fetch_addr (addr)
    value_at(addr)
  end

  def copy_data (data)
    data.elements.times { |i| data[i] = value_at(i) }
  end

  # (starts, counts, steps) is an index box over this object's own axes --
  # so a position outside an axis is the caller handing over a region that
  # is not ours to answer.
  def copy_block (starts, counts, steps, data)
    counts[0].times do |i|
      counts[1].times do |j|
        vi = starts[0] + i * steps[0]
        vj = starts[1] + j * steps[1]
        if vi >= @n || vj >= @m
          raise IndexError, "copy_block region runs off the object: [#{vi}, #{vj}]"
        end
        data[i, j] = value_at(vi * @m + vj)
      end
    end
  end
end

class TestXferStrideTransposedRequest < Test::Unit::TestCase

  # Column-major request over a 2-D view: axes reversed, cells packed in
  # that order.  Returns [request_starts, request_counts, request_steps].
  def column_major_request (view)
    dim    = view.dim
    native = [dim[1], 1]                       # cells per step along each axis
    [[0, 0], [dim[1], dim[0]], [native[1], native[0]]]
  end

  # What the view itself says the request selects: walk the request on the
  # view's addresses, read each cell through the view's own indexing.
  def expected_cells (view, starts, counts, steps)
    dim  = view.dim
    base = starts[0] * dim[1] + starts[1]
    out  = []
    counts[0].times do |i|
      counts[1].times do |j|
        addr = base + i * steps[0] + j * steps[1]
        out << view[addr / dim[1], addr % dim[1]]
      end
    end
    out
  end

  def assert_column_major_region (view, label)
    starts, counts, steps = column_major_request(view)
    got = CArray.bench_xfer_stride_region_get(view, starts, counts, steps)
                .unpack("d*")
    assert_equal(expected_cells(view, starts, counts, steps), got,
                 "#{label} (#{view.class}, dim=#{view.dim.inspect}) " \
                 "delivered the wrong cells for a column-major request")
  end

  # Both shapes matter: (n, 1) is where the degenerate axis hides the
  # transposition, (n, 2) is the ordinary case that must keep working.
  def each_shape
    yield 3, 1
    yield 3, 2
  end

  def source (n, m)
    CArray.float64(n, m) { |i, j| (i + 1) * 10.0 + j }
  end

  def test_castride_promoted_vector
    # The path the report came in on: a 1-D vector promoted to a column.
    v = CArray.float64(3).seq(10.0, 10.0)
    assert_column_major_region(v[nil, :_], "promoted vector")
    assert_column_major_region(v.reshape(3, 1), "reshaped vector")
  end

  def test_castride
    each_shape do |n, m|
      assert_column_major_region(source(n, m).reshape(n, m), "stride")
    end
  end

  def test_cablock
    each_shape do |n, m|
      big = CArray.float64(n + 2, m + 2) { |i, j| (i + 1) * 10.0 + j }
      assert_column_major_region(big[1..n, 1..m], "block")
    end
  end

  def test_catranspose
    each_shape do |n, m|
      assert_column_major_region(source(m, n).transpose, "transpose")
    end
  end

  def test_carefer
    each_shape do |n, m|
      assert_column_major_region(source(n, m).refer(CA_FLOAT64, [n, m]), "refer")
    end
  end

  def test_caroll
    each_shape do |n, m|
      assert_column_major_region(source(n, m).roll(-1, 0), "roll")
    end
  end

  def test_cawindow
    each_shape do |n, m|
      assert_column_major_region(source(n, m).window(0..n-1, 0..m-1,
                                                     fill_value: -1.0), "window")
    end
  end

  def test_catile
    each_shape do |n, m|
      assert_column_major_region(source(n, m).tile(1, 1), "tile")
    end
  end

  def test_cagrid
    each_shape do |n, m|
      g = source(n, m)
      view = g[CA_INT32((0...n).to_a), CA_INT32((0...m).to_a)]
      assert_column_major_region(view, "grid")
    end
  end

  def test_caselectaxis
    each_shape do |n, m|
      big  = CArray.float64(n + 1, m) { |i, j| (i + 1) * 10.0 + j }
      pick = CArray.boolean(n + 1) { |i| i < n ? 1 : 0 }
      assert_column_major_region(big[pick, nil], "select-axis")
    end
  end

  def test_caobject_with_copy_block
    each_shape do |n, m|
      view = TransposedRequestSource.new(n, m)
      assert_column_major_region(view, "caobject copy_block")
    end
  end
end
