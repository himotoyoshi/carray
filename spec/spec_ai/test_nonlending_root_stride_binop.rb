require "test/unit"
require "carray"

# A CAStride view over a root with no memory to lend (a lazy per-element
# transform, a CAObject) answers a region request by composing it into the
# root's addresses and asking once, instead of descending cell by cell.
#
# The region entry is what the two-operand drivers gather through per chunk
# (binop / triop / bincmp), so before the fix each of those asked the root
# once per cell -- correct, but ~90 ns/element against ~1 for the same
# operands materialised by hand.  The single-operand drivers took a one-shot
# materialise instead and were never affected, which is why the defect only
# showed when both operands were such views.
#
# See devel/PROPOSAL_NONLENDING_ROOT_STRIDE_BINOP.md.
class TestNonLendingRootStrideBinop < Test::Unit::TestCase

  N = 40

  def setup
    @sq   = CArray.float64(N, N) { |j, i| (i * 7 + j * 3) % 97 - 40 }
    @lazy = (@sq.lazy + 0.5)          # CABinOp: computes, lends nothing
    @mono = @sq.lazy.neg              # CAMonOp: likewise
  end

  # Values through the view must equal values with each operand materialised
  # first -- that is the whole contract the region hand-down has to keep.
  def check(root, label)
    v0 = root[0..N - 5, nil]
    v1 = root[4..N - 1, nil]
    c0 = v0.copy
    c1 = v1.copy

    assert_equal (c0 + c1).to_a,          (v0 + v1).to_a,          "#{label}: binop +"
    assert_equal (c0 * c1).to_a,          (v0 * v1).to_a,          "#{label}: binop *"
    assert_equal (c0 > c1).to_a,          (v0 > c1.to_ca).to_a,    "#{label}: bincmp vs entity"
    assert_equal (c0 > c1).to_a,          (v0 > v1).to_a,          "#{label}: bincmp"
    assert_equal c0.fma(c1, c1).to_a,     v0.fma(v1, v1).to_a,     "#{label}: triop"
    assert_equal (c0 + c0).to_a,          (v0 + v0).to_a,          "#{label}: same operand"
    assert_equal c0.sin.to_a,             v0.sin.to_a,             "#{label}: monop"
  end

  def test_binop_over_lazy_binop_root
    check(@lazy, "CABinOp root")
  end

  def test_binop_over_lazy_monop_root
    check(@mono, "CAMonOp root")
  end

  # A transposed view puts a negative-free but non-contiguous layout on the
  # composed strides; a flipped one makes a stride negative.  Both compose to
  # the same root, so both go down the region hand-down.
  def test_reordered_and_flipped_views
    t0 = @lazy.transpose[0..N - 5, nil]
    t1 = @lazy.transpose[4..N - 1, nil]
    assert_equal (t0.copy + t1.copy).to_a, (t0 + t1).to_a, "transposed"

    f0 = @lazy[-1..0, nil][0..N - 5, nil]
    f1 = @lazy[-1..0, nil][4..N - 1, nil]
    assert_equal (f0.copy + f1.copy).to_a, (f0 + f1).to_a, "flipped"

    s0 = @lazy[0..N - 5, [0, N / 2, 2]]
    s1 = @lazy[4..N - 1, [0, N / 2, 2]]
    assert_equal (s0.copy + s1.copy).to_a, (s0 + s1).to_a, "strided inner"
  end

  # A masked lazy root keeps its mask through the region hand-down.
  def test_mask_survives
    m = @sq.copy
    m[0..3, nil] = UNDEF
    lz = (m.lazy + 0.5)
    v0 = lz[0..N - 5, nil]
    v1 = lz[4..N - 1, nil]
    assert_equal (v0.copy + v1.copy).mask.to_a, (v0 + v1).mask.to_a
    assert_equal (v0.copy + v1.copy).to_a,      (v0 + v1).to_a
  end

  # The root is asked a bounded number of times, not once per cell.  The
  # count is the chunking policy's, so pin only that it is far below the
  # element count -- the defect was exactly one call per cell per operand.
  def test_root_is_asked_in_regions_not_per_cell
    v0 = @lazy[0..N - 5, nil]
    v1 = @lazy[4..N - 1, nil]
    CABinOp.__reset_materialise_counter__
    v0 + v1
    calls = CABinOp.__materialise_count__
    assert_operator calls, :<, v0.elements / 10,
                    "root asked #{calls} times for #{v0.elements} cells"
  end
end
