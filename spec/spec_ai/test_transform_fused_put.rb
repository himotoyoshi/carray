require 'carray'
require 'test/unit'

# Regression test for the silent-write-loss bug fixed by
# PROPOSAL_TRANSFORM_FUSED_XFER rev3 Phase 2/3 (2026-05-31).
#
# Before transform-fused, `a.transpose.fake(:int32)[] = src` (and similar
# CATranspose-of-CAFake / CATranspose-of-CAByteSwap chains via xfer_all PUT)
# went through ca_fake_func_xfer_all's legacy `ca_attach(parent) +
# ca_cast_block + ca_detach(parent)` path. The detach (= ca_stride_func_detach)
# xfreed the buffer without ca_sync(root), so the write was silently lost.
#
# After Phase 2/3, CAFake/CAByteSwap.xfer_all delegates to xfer_stride when
# parent is in the CAStride family, which routes through the fused helper's
# scatter-back path. The write actually reaches the entity.
#
# This test pins the correct PUT behavior so the regression cannot return.

class TestTransformFusedPut < Test::Unit::TestCase

  # ---- CAFake.xfer_all PUT through CATranspose to entity ----

  def test_cafake_transpose_put_actually_writes
    a = CArray.float64(4, 4).tap { |x| x[] = x.seq + 100 }
    src = CArray.int32(4, 4).tap { |x| x[] = x.seq + 1000 }
    a.transpose.fake(:int32)[] = src
    # Expected: a[i,j] = (float64)src[j,i]  (= transpose-then-cast)
    expected = Array.new(4) { |i|
      Array.new(4) { |j| (1000 + j * 4 + i).to_f }
    }
    assert_equal(expected, a.to_a,
                 "PUT through CATranspose-of-CAFake chain must actually write the data; " \
                 "legacy code silently discarded the write (see PROPOSAL_TRANSFORM_FUSED_XFER 補記)")
  end

  def test_cafake_transpose_put_2x2_simple
    a = CArray.float64(2, 2) { 0.0 }
    src = CArray.int32(2, 2).tap { |x| x[] = x.seq + 10 }   # [[10, 11], [12, 13]]
    a.transpose.fake(:int32)[] = src
    # a[i,j] = src[j,i]
    assert_equal([[10.0, 12.0], [11.0, 13.0]], a.to_a)
  end

  # ---- CAByteSwap.xfer_all PUT through CATranspose to entity ----

  def test_cabyteswap_transpose_put_actually_writes
    a = CArray.int32(4, 4).tap { |x| x[] = x.seq + 1000 }
    a_orig = a.to_a
    src = CArray.int32(4, 4).tap { |x| x[] = x.seq + 2000 }
    # Round-trip: write byteswapped values, then read them back through the
    # same view. They must round-trip identically (= byteswap is involutive).
    a.transpose.endian(:big)[] = src.transpose.endian(:big).to_ca
    # After writing back through the swap-of-transpose, a should hold
    # transposed (and byte-roundtripped) src values.
    expected = Array.new(4) { |i| Array.new(4) { |j| 2000 + i * 4 + j } }
    assert_equal(expected, a.to_a,
                 "PUT through CATranspose-of-CAByteSwap chain must actually write")
  end

  # ---- CAFake direct PUT (no transpose) still works ----

  def test_cafake_put_no_transpose
    a = CArray.float64(4, 4) { 0.0 }
    src = CArray.int32(4, 4).tap { |x| x[] = x.seq + 100 }
    a.fake(:int32)[] = src
    expected = Array.new(4) { |i| Array.new(4) { |j| (100 + i * 4 + j).to_f } }
    assert_equal(expected, a.to_a)
  end

  # ---- Different chain order (B-spelling): a.fake.transpose ----

  def test_cafake_outer_transpose_put_writes
    # Chain: CATranspose(CAFake(entity)). a.fake(:int32).transpose[] = src
    # PUT semantics: src[i,j] becomes a's cell at transposed (j,i), cast to float
    a = CArray.float64(4, 4) { 0.0 }
    src = CArray.int32(4, 4).tap { |x| x[] = x.seq + 1000 }
    a.fake(:int32).transpose[] = src
    # a[i,j] = (float64)src[j,i]
    expected = Array.new(4) { |i|
      Array.new(4) { |j| (1000 + j * 4 + i).to_f }
    }
    assert_equal(expected, a.to_a)
  end

  # ---- Sub-region PUT must not crash + must affect SOMETHING (= not silent no-op) ----

  def test_cafake_transpose_put_sub_region_not_silent_noop
    a = CArray.float64(6, 6).tap { |x| x[] = x.seq + 100 }
    a_before = a.to_a
    src = CArray.int32(3, 3).tap { |x| x[] = x.seq + 1000 }
    a.transpose.fake(:int32)[1..3, 2..4] = src
    refute_equal(a_before, a.to_a,
                 "sub-region PUT through CATranspose-of-CAFake chain " \
                 "must change SOME cells of a (= not silent no-op)")
  end

  # Pre-2026-05-31: ca_xfer_stride_transform_fused used view->dim[ndim-1]
  # instead of counts[ndim-1] for inner_count, so sub-region PUT through
  # CATranspose-of-CAFake (or CAFake-of-CATranspose) wrote more cells than
  # requested, corrupting adjacent heap memory.  The process crashed at GC
  # finalize (free_carray dereferencing an overwritten mask pointer).
  # This regression pin verifies (1) the sub-region PUT lands at the
  # correct transposed cells with correct cast values, AND (2) does not
  # corrupt cells outside the target region.
  def test_cafake_transpose_put_sub_region_exact_values
    a = CArray.float64(6, 6).tap { |x| x[] = x.seq + 100 }
    src = CArray.int32(3, 3).tap { |x| x[] = x.seq + 1000 }   # [[1000..1002], [1003..1005], [1006..1008]]
    a.transpose.fake(:int32)[1..3, 2..4] = src
    # View `a.transpose.fake(:int32)` writes to a's TRANSPOSED position.
    # block [1..3, 2..4] in view space = a[(2..4), (1..3)] in entity space.
    # Per-cell: view[bi+1, bj+2] = src[bi, bj]  =>  a[bj+2, bi+1] = (f64)src[bi,bj]
    expected = [
      [100.0, 101.0, 102.0, 103.0, 104.0, 105.0],
      [106.0, 107.0, 108.0, 109.0, 110.0, 111.0],
      [112.0, 1000.0, 1003.0, 1006.0, 116.0, 117.0],
      [118.0, 1001.0, 1004.0, 1007.0, 122.0, 123.0],
      [124.0, 1002.0, 1005.0, 1008.0, 128.0, 129.0],
      [130.0, 131.0, 132.0, 133.0, 134.0, 135.0],
    ]
    assert_equal(expected, a.to_a,
                 "sub-region PUT must (1) write transposed-cast values to the " \
                 "block target cells AND (2) leave adjacent cells untouched")
  end

  # Mirror with the B-spelling (fake-then-transpose) to cover both chain orders.
  def test_cafake_outer_transpose_put_sub_region_exact_values
    a = CArray.float64(6, 6).tap { |x| x[] = x.seq + 100 }
    src = CArray.int32(3, 3).tap { |x| x[] = x.seq + 1000 }
    a.fake(:int32).transpose[1..3, 2..4] = src
    # Same transposed semantics as A-spelling.
    expected = [
      [100.0, 101.0, 102.0, 103.0, 104.0, 105.0],
      [106.0, 107.0, 108.0, 109.0, 110.0, 111.0],
      [112.0, 1000.0, 1003.0, 1006.0, 116.0, 117.0],
      [118.0, 1001.0, 1004.0, 1007.0, 122.0, 123.0],
      [124.0, 1002.0, 1005.0, 1008.0, 128.0, 129.0],
      [130.0, 131.0, 132.0, 133.0, 134.0, 135.0],
    ]
    assert_equal(expected, a.to_a,
                 "sub-region PUT via fake.transpose chain must have same " \
                 "semantics as transpose.fake")
  end
end
