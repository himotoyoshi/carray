/* ---------------------------------------------------------------------------

  CAMeld view = ragged concatenate along an existing axis of K parents.

  shape[a]         = parents[0]->dim[a]           for a != meld_axis
  shape[meld_axis] = sum_k parents[k]->dim[meld_axis]

  Segment boundaries are held as an explicit prefix-sum table (seg_offset)
  so segment resolution is per-segment (K-1 boundaries) rather than per-cell.
  User sees a welded axis; engine keeps the segments.

  Op coverage (all accept arbitrary meld_axis):
    xfer_all:
      meld_axis == 0     = K contig xfer_all into per-segment slots (best,
                           memcpy-bound)
      meld_axis != 0     = per-parent slab buf gather + row-major
                           scatter/gather (adapted from CAStack k_axis!=0)
    xfer_stride:
      structural + ma==0 = K contig xfer_stride into per-segment slot
      structural + ma!=0 = per-segment slab buf + row-major scatter/gather
      non-structural     = per-cell fallback via xfer_index (universal
                           safety net; correctness-first, not perf-optimised)
    xfer_index:            binary-search seg_offset + parent dispatch
    xfer_addrs:            naive per-addr binary search (O(n log K))
                           (sortedness-aware O(n+K) merge is a future
                           optimisation, memo §7.3)
    fill_data:             K-fold ca_fill
    create_mask:           horizontal propagation (mirrors CAStack)
    fold_stride:           decline (return 0)

  Design ref: devel/MEMO_CAMELD_SEGMENT_MAJOR_ENGINE.md.  Meld-axis reduce
  fast path (per-parent decompose, eager parity) lives in Ruby land at
  lib/carray/meld_reduce.rb.  The internal-axis paths above give the
  deliver-it-anyway correctness contract; they are not tile-cache
  optimised, but
  since all decomposable reductions bypass xfer_all/xfer_stride via the
  Ruby fast path, this rarely matters in practice.

---------------------------------------------------------------------------- */

#include "carray.h"

/* ------------------------------------------------------------------- */
/* TypedData                                                            */
/* ------------------------------------------------------------------- */

static size_t
ca_meld_dsize (const void *ap)
{
  const CAMeld *ca = (const CAMeld *) ap;
  return sizeof(CAMeld)
       + ca->ndim * sizeof(ca_size_t)                /* dim[] */
       + ca->n_parents * sizeof(CArray *)             /* parents[] */
       + (ca->n_parents + 1) * sizeof(ca_size_t);     /* seg_offset[] */
}

const rb_data_type_t cameld_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAMeld",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_meld_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t cameld_mask_data_type = {
    .parent = &cameld_data_type,
    .wrap_struct_name = "CAMeldMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_meld_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_MELD;

VALUE rb_cCAMeld;
VALUE rb_cCAMeldMask;

static ID id_parents;

/* ------------------------------------------------------------------- */
/* uniform check                                                        */
/* ------------------------------------------------------------------- */

/* Parents must share data type, ndim, bytes, and all dims except meld_axis;
   meld_axis lengths are the ragged dimension (may differ). */
static void
ca_meld_check_uniform (int32_t n_parents, CArray **parents, int8_t meld_axis)
{
  CArray *ref;
  int32_t i;
  int8_t k;
  if ( n_parents <= 0 ) {
    rb_raise(rb_eArgError, "CAMeld requires at least one parent");
  }
  ref = parents[0];
  if ( meld_axis < 0 || meld_axis >= ref->ndim ) {
    rb_raise(rb_eArgError,
             "CAMeld meld_axis %d out of range [0, %d)",
             (int) meld_axis, (int) ref->ndim);
  }
  for ( i = 1; i < n_parents; i++ ) {
    CArray *p = parents[i];
    if ( p->data_type != ref->data_type ) {
      rb_raise(rb_eArgError,
               "CAMeld parents must have uniform data_type "
               "(parent[0]=%d, parent[%d]=%d)",
               ref->data_type, i, p->data_type);
    }
    if ( p->ndim != ref->ndim ) {
      rb_raise(rb_eArgError,
               "CAMeld parents must have uniform ndim "
               "(parent[0]=%d, parent[%d]=%d)",
               ref->ndim, i, p->ndim);
    }
    if ( p->bytes != ref->bytes ) {
      rb_raise(rb_eArgError,
               "CAMeld parents must have uniform bytes "
               "(parent[0]=%lld, parent[%d]=%lld)",
               (long long) ref->bytes, i, (long long) p->bytes);
    }
    for ( k = 0; k < ref->ndim; k++ ) {
      if ( k == meld_axis ) continue;
      if ( p->dim[k] != ref->dim[k] ) {
        rb_raise(rb_eArgError,
                 "CAMeld parents must have uniform shape except at meld_axis %d "
                 "(mismatch at axis %d: parent[0]=%lld, parent[%d]=%lld)",
                 (int) meld_axis, (int) k,
                 (long long) ref->dim[k], i, (long long) p->dim[k]);
      }
    }
  }
}

/* ------------------------------------------------------------------- */
/* setup / new / free / clone                                           */
/* ------------------------------------------------------------------- */

int
ca_meld_setup (CAMeld *ca, int32_t n_parents, CArray **parents, int8_t meld_axis)
{
  CArray *ref;
  int32_t i;
  int8_t  a;

  ca_meld_check_uniform(n_parents, parents, meld_axis);
  ref = parents[0];

  ca->obj_type  = CA_OBJ_MELD;
  ca->data_type = ref->data_type;
  ca->flags     = CA_FLAG_MULTI_PARENTS;
  ca->ndim      = ref->ndim;
  ca->bytes     = ref->bytes;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->_pool     = NULL;

  ca->parent    = ref;         /* CAView base = parents[0] */
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->n_parents = n_parents;
  ca->parents   = ALLOC_N(CArray *, n_parents);
  for ( i = 0; i < n_parents; i++ ) {
    ca->parents[i] = parents[i];
  }
  ca->meld_axis = meld_axis;

  /* Prefix-sum along meld_axis: seg_offset[k+1] = seg_offset[k] + parents[k]->dim[meld_axis]. */
  ca->seg_offset = ALLOC_N(ca_size_t, n_parents + 1);
  ca->seg_offset[0] = 0;
  for ( i = 0; i < n_parents; i++ ) {
    ca->seg_offset[i + 1] = ca->seg_offset[i] + parents[i]->dim[meld_axis];
  }

  ca->dim = ALLOC_N(ca_size_t, ca->ndim);
  for ( a = 0; a < ca->ndim; a++ ) {
    ca->dim[a] = (a == meld_axis) ? ca->seg_offset[n_parents] : ref->dim[a];
  }

  ca->elements = 0;
  for ( i = 0; i < n_parents; i++ ) ca->elements += parents[i]->elements;

  return 0;
}

CAMeld *
ca_meld_new (int32_t n_parents, CArray **parents, int8_t meld_axis)
{
  CAMeld *ca = ALLOC(CAMeld);
  ca_meld_setup(ca, n_parents, parents, meld_axis);
  return ca;
}

static void
free_ca_meld (void *ap)
{
  /* CAREFUL: `parents[]` is an alias array we allocated with ALLOC_N in
     ca_meld_setup; individual parent CArrays are kept alive by the Ruby
     wrapper's `@parents` ivar (set by rb_ca_meld_new / rb_ca_meld_initialize).
     So we xfree the tail here but never touch parent contents. */
  CAMeld *ca = (CAMeld *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->seg_offset);
    xfree(ca->parents);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_meld_func_clone (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  return ca_meld_new(ca->n_parents, ca->parents, ca->meld_axis);
}

/* ------------------------------------------------------------------- */
/* helpers                                                              */
/* ------------------------------------------------------------------- */

/* Binary search: return k such that seg_offset[k] <= v < seg_offset[k+1].
   Precondition: 0 <= v < seg_offset[n_parents]. */
static inline int32_t
ca_meld_segment_of (const CAMeld *ca, ca_size_t v)
{
  int32_t lo = 0, hi = ca->n_parents;
  while ( hi - lo > 1 ) {
    int32_t mid = (lo + hi) >> 1;
    if ( ca->seg_offset[mid] <= v ) lo = mid;
    else                            hi = mid;
  }
  return lo;
}

/* Product of dims [meld_axis+1 .. ndim-1] (the tail after meld_axis).  For
   meld_axis == 0 this is the "row size in elements" for each meld_axis step. */
static inline ca_size_t
ca_meld_tail_elements (const CAMeld *ca)
{
  int8_t a;
  ca_size_t p = 1;
  for ( a = ca->meld_axis + 1; a < ca->ndim; a++ ) p *= ca->dim[a];
  return p;
}

/* ------------------------------------------------------------------- */
/* xfer_index                                                           */
/* ------------------------------------------------------------------- */

/* view[..., v at meld_axis, ...] = parents[k][..., v - seg_offset[k], ...]
   where k = segment_of(v). */
static void
ca_meld_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAMeld *ca = (CAMeld *) ap;
  int8_t   ma = ca->meld_axis;
  ca_size_t v = idx[ma];
  int32_t   k;
  ca_size_t pidx[CA_RANK_MAX];
  int8_t    a;

  if ( v < 0 || v >= ca->dim[ma] ) {
    rb_raise(rb_eIndexError,
             "CAMeld meld_axis (axis %d) index %lld out of range [0, %lld)",
             (int) ma, (long long) v, (long long) ca->dim[ma]);
  }
  k = ca_meld_segment_of(ca, v);
  for ( a = 0; a < ca->ndim; a++ ) pidx[a] = idx[a];
  pidx[ma] = v - ca->seg_offset[k];
  ca_xfer_index(ca->parents[k], pidx, data, dir);
}

/* ------------------------------------------------------------------- */
/* xfer_addrs — K-pass per-parent bucket                                */
/* ------------------------------------------------------------------- */

/* For each parent k, scan all n addrs and pick those whose meld-axis
   coordinate lands in [seg_offset[k], seg_offset[k+1]).  Total cost is
   O(n·K) (K linear scans over n addrs); per-addr binary-search + K-way
   bucket would drop this to O(n log K) with more temp storage, and a
   sortedness-aware merge on sorted addrs (typical for boolean-mask
   access) would give O(n+K) — both are demand-driven follow-ons.  The
   K-pass structure keeps peak scratch to a single (n * bytes) slab
   shared across all parents. */
static void
ca_meld_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir)
{
  CAMeld *ca = (CAMeld *) ap;
  int8_t   ma = ca->meld_axis;
  ca_size_t bytes = ca->bytes;
  ca_size_t view_div[CA_RANK_MAX];   /* row-major divisor per view axis */
  ca_size_t parent_mul[CA_RANK_MAX]; /* per-parent (recomputed inside k loop) */
  ca_size_t *paddrs;
  char     *pdata, *cdata = (char *) data;
  volatile VALUE holder1, holder2;
  ca_size_t s, i;
  int32_t   k;
  int8_t    a;

  paddrs = ALLOCV_N(ca_size_t, holder1, n);
  pdata  = ALLOCV_N(char, holder2, n * bytes);

  s = 1;
  for ( a = ca->ndim - 1; a >= 0; a-- ) { view_div[a] = s; s *= ca->dim[a]; }

  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_size_t seg_lo = ca->seg_offset[k];
    ca_size_t seg_hi = ca->seg_offset[k + 1];
    ca_size_t parent_meld_len = seg_hi - seg_lo;
    ca_size_t m = 0;

    /* Per-parent row-major multiplier: uses parent[0]'s dims for non-meld
       axes (uniform check) and this parent's segment length at meld_axis. */
    s = 1;
    for ( a = ca->ndim - 1; a >= 0; a-- ) {
      parent_mul[a] = s;
      if ( a == ma ) s *= parent_meld_len;
      else           s *= ca->parents[0]->dim[a];
    }

    for ( i = 0; i < n; i++ ) {
      ca_size_t addr = addrs[i];
      ca_size_t vidx_ma = (addr / view_div[ma]) % ca->dim[ma];
      ca_size_t paddr;
      if ( vidx_ma < seg_lo || vidx_ma >= seg_hi ) continue;
      paddr = 0;
      for ( a = 0; a < ca->ndim; a++ ) {
        ca_size_t vv = (addr / view_div[a]) % ca->dim[a];
        if ( a == ma ) vv -= seg_lo;
        paddr += vv * parent_mul[a];
      }
      paddrs[m] = paddr;
      if ( dir == CA_XFER_PUT ) {
        memcpy(pdata + m * bytes, cdata + i * bytes, bytes);
      }
      m++;
    }
    if ( m > 0 ) {
      ca_xfer_addrs(ca->parents[k], m, paddrs, pdata, dir);
      if ( dir == CA_XFER_GET ) {
        ca_size_t mm = 0;
        for ( i = 0; i < n; i++ ) {
          ca_size_t addr = addrs[i];
          ca_size_t vidx_ma = (addr / view_div[ma]) % ca->dim[ma];
          if ( vidx_ma < seg_lo || vidx_ma >= seg_hi ) continue;
          memcpy(cdata + i * bytes, pdata + mm * bytes, bytes);
          mm++;
        }
      }
    }
  }

  ALLOCV_END(holder2);
  ALLOCV_END(holder1);
}

/* ------------------------------------------------------------------- */
/* xfer_stride                                                          */
/* ------------------------------------------------------------------- */

/* Structural best path (meld_axis == 0): K contig xfer_stride calls, each
   parent's row-major output is a contig slot in dst -- zero copy. */
static void
ca_meld_xfer_stride_ma0 (CAMeld *ca, ca_size_t *starts, ca_size_t *counts,
                         ca_size_t *strides, void *data, int dir)
{
  ca_size_t native[CA_RANK_MAX], dstride[CA_RANK_MAX];
  ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
  ca_size_t s, req_lo, req_hi;
  int32_t   k_lo, k_hi, k;
  int8_t    i;
  char     *d = (char *) data;

  s = ca->bytes;
  for ( i = ca->ndim - 1; i >= 0; i-- ) { native[i] = s; s *= ca->dim[i]; }
  for ( i = 0; i < ca->ndim; i++ ) pstrides[i] = native[i];

  s = ca->bytes;
  for ( i = ca->ndim - 1; i >= 0; i-- ) { dstride[i] = s; s *= counts[i]; }

  req_lo = starts[0];
  req_hi = starts[0] + counts[0];
  if ( req_hi <= req_lo ) return;
  k_lo = ca_meld_segment_of(ca, req_lo);
  k_hi = ca_meld_segment_of(ca, req_hi - 1) + 1;

  for ( i = 1; i < ca->ndim; i++ ) { pstarts[i] = starts[i]; pcounts[i] = counts[i]; }

  for ( k = k_lo; k < k_hi; k++ ) {
    ca_size_t seg_lo = ca->seg_offset[k];
    ca_size_t seg_hi = ca->seg_offset[k + 1];
    ca_size_t view_lo = (req_lo > seg_lo) ? req_lo : seg_lo;
    ca_size_t view_hi = (req_hi < seg_hi) ? req_hi : seg_hi;
    ca_size_t slot_off = (view_lo - req_lo) * dstride[0];
    pstarts[0] = view_lo - seg_lo;
    pcounts[0] = view_hi - view_lo;
    ca_xfer_stride(ca->parents[k], pstarts, pcounts, pstrides, d + slot_off, dir);
  }
}

/* Internal-axis structural path (meld_axis != 0): per-segment slab buf
   gather, then row-major scatter/gather to dst at view-strided positions.
   The K stride sits mid-order so each parent's row-major slab does not fit
   contig in dst.  Follows CAStack's k_axis!=0 xfer_stride shape adapted
   to segment-variable lengths. */
static void
ca_meld_xfer_stride_ma_internal (CAMeld *ca, ca_size_t *starts,
                                 ca_size_t *counts, void *data, int dir)
{
  int8_t   ma = ca->meld_axis;
  int8_t   ndim = ca->ndim;
  ca_size_t bytes = ca->bytes;
  ca_size_t dstride[CA_RANK_MAX], pstrides[CA_RANK_MAX];
  ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX];
  ca_size_t req_lo, req_hi;
  int32_t   k_lo, k_hi, k;
  int8_t    i;
  ca_size_t s;
  char     *d = (char *) data;

  /* dst row-major over output counts[] */
  s = bytes;
  for ( i = ndim - 1; i >= 0; i-- ) { dstride[i] = s; s *= counts[i]; }

  req_lo = starts[ma];
  req_hi = starts[ma] + counts[ma];
  if ( req_hi <= req_lo ) return;
  k_lo = ca_meld_segment_of(ca, req_lo);
  k_hi = ca_meld_segment_of(ca, req_hi - 1) + 1;

  /* Non-meld pstarts/pcounts pass through */
  for ( i = 0; i < ndim; i++ ) {
    if ( i == ma ) continue;
    pstarts[i] = starts[i];
    pcounts[i] = counts[i];
  }

  for ( k = k_lo; k < k_hi; k++ ) {
    CArray *p = ca->parents[k];
    ca_size_t seg_lo = ca->seg_offset[k];
    ca_size_t seg_hi = ca->seg_offset[k + 1];
    ca_size_t view_lo = (req_lo > seg_lo) ? req_lo : seg_lo;
    ca_size_t view_hi = (req_hi < seg_hi) ? req_hi : seg_hi;
    ca_size_t ma_off_in_dst = view_lo - req_lo;
    ca_size_t inner_dim[CA_RANK_MAX];
    ca_size_t slab_bytes = bytes;
    volatile VALUE holder;
    char *buf;
    ca_size_t paddr;

    pstarts[ma] = view_lo - seg_lo;
    pcounts[ma] = view_hi - view_lo;
    for ( i = 0; i < ndim; i++ ) {
      inner_dim[i] = pcounts[i];
      slab_bytes *= pcounts[i];
    }

    /* pstrides is the SOURCE stride the parent uses to walk its own memory
       (see ca_xfer_stride_dispatch + ca_xfer_strided_walk in carray_core.c:
       for an entity source `strides` argument = byte offsets into
       parent.ptr; dst walks contig via doff += slab_bytes).  So pstrides
       must be p's native row-major byte strides (based on p->dim), not
       pcounts.  partial-slab pcounts[i] < p->dim[i] just narrows the walk
       range (counts) without changing the source layout. */
    s = bytes;
    for ( i = ndim - 1; i >= 0; i-- ) {
      pstrides[i] = s;
      s *= p->dim[i];
    }

    buf = ALLOCV_N(char, holder, slab_bytes);

    if ( dir == CA_XFER_GET ) {
      ca_xfer_stride(p, pstarts, pcounts, pstrides, buf, CA_XFER_GET);
    }

    /* Scatter/gather buf to dst using trailing-chunk memcpy.
       Trailing block from meld_axis..ndim-1 is contig in BOTH parent slab
       (row-major over pcounts[]) and dst (dst row-major stride dstride[]),
       because within one parent + one outer combo, cells (ma..ndim-1) map
       to a contig run in dst starting at ma_off_in_dst on meld_axis.
       So we memcpy chunk_bytes = Π pcounts[ma..ndim-1] * bytes and only
       odometer over outer axes 0..ma-1. */
    paddr = 0;
    {
      ca_size_t voff = ma_off_in_dst * dstride[ma];
      ca_size_t outer_step[CA_RANK_MAX], outer_back[CA_RANK_MAX];
      ca_size_t outer_idx[CA_RANK_MAX];
      ca_size_t chunk_bytes;
      /* chunk_bytes = product of pcounts[ma..ndim-1] * bytes */
      chunk_bytes = bytes;
      for ( i = ma; i < ndim; i++ ) chunk_bytes *= inner_dim[i];
      for ( i = 0; i < ma; i++ ) {
        outer_step[i] = dstride[i];
        outer_back[i] = (inner_dim[i] - 1) * dstride[i];
        outer_idx[i]  = 0;
      }
      if ( ma == 0 ) {
        /* Guard (should not fire — caller dispatches ma==0 elsewhere) */
        if ( dir == CA_XFER_GET ) memcpy(d + voff, buf, chunk_bytes);
        else                      memcpy(buf, d + voff, chunk_bytes);
      }
      else if ( dir == CA_XFER_GET ) {
        while ( 1 ) {
          memcpy(d + voff, buf + paddr, chunk_bytes);
          paddr += chunk_bytes;
          i = ma - 1;
          while ( i >= 0 ) {
            if ( ++outer_idx[i] < inner_dim[i] ) { voff += outer_step[i]; break; }
            outer_idx[i] = 0;
            voff -= outer_back[i];
            i--;
          }
          if ( i < 0 ) break;
        }
      } else {
        while ( 1 ) {
          memcpy(buf + paddr, d + voff, chunk_bytes);
          paddr += chunk_bytes;
          i = ma - 1;
          while ( i >= 0 ) {
            if ( ++outer_idx[i] < inner_dim[i] ) { voff += outer_step[i]; break; }
            outer_idx[i] = 0;
            voff -= outer_back[i];
            i--;
          }
          if ( i < 0 ) break;
        }
      }
    }

    if ( dir == CA_XFER_PUT ) {
      ca_xfer_stride(p, pstarts, pcounts, pstrides, buf, CA_XFER_PUT);
    }
    ALLOCV_END(holder);
  }
}

/* Non-structural fallback: per-cell xfer_index.  Universal correctness
   safety net for arbitrary strides (works for any meld_axis, including
   permutations like transpose).  Follows CAStack's per-cell shape:
     base = Σ starts[k] * native[k]         (byte addr in flat root space)
     toff = base + Σ idx[k]  * strides[k]   (composed byte offset)
     addr2index(root, toff/bytes) → source N-D index
     xfer_index at source idx, dst walks contig by bytes.
   Slow but correct; hot paths stay on the structural branches above. */
static void
ca_meld_xfer_stride_per_cell (CAMeld *ca, ca_size_t *starts, ca_size_t *counts,
                              ca_size_t *strides, void *data, int dir)
{
  int8_t ndim = ca->ndim;
  ca_size_t native[CA_RANK_MAX];
  ca_size_t idx[CA_RANK_MAX], vidx[CA_RANK_MAX];
  ca_size_t base = 0, doff = 0, s;
  char *d = (char *) data;
  int8_t i;

  CA_ASSUME(ndim >= 0 && ndim <= CA_RANK_MAX);   /* bound loops over [CA_RANK_MAX] arrays */
  s = ca->bytes;
  for ( i = ndim - 1; i >= 0; i-- ) { native[i] = s; s *= ca->dim[i]; }
  for ( i = 0; i < ndim; i++ ) base += starts[i] * native[i];
  for ( i = 0; i < ndim; i++ ) idx[i] = 0;

  while ( 1 ) {
    ca_size_t toff = base;
    for ( i = 0; i < ndim; i++ ) toff += idx[i] * strides[i];
    ca_addr2index((CArray *) ca, toff / ca->bytes, vidx);
    ca_meld_func_xfer_index(ca, vidx, d + doff, dir);
    doff += ca->bytes;
    i = ndim - 1;
    while ( i >= 0 ) {
      if ( ++idx[i] < counts[i] ) break;
      idx[i] = 0;
      i--;
    }
    if ( i < 0 ) break;
  }
}

static void
ca_meld_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir)
{
  CAMeld *ca = (CAMeld *) ap;
  int8_t   ma = ca->meld_axis;
  ca_size_t native[CA_RANK_MAX];
  ca_size_t s;
  int8_t   i;
  int      structural = 1;

  s = ca->bytes;
  for ( i = ca->ndim - 1; i >= 0; i-- ) { native[i] = s; s *= ca->dim[i]; }

  /* Bound check on meld_axis.  The step along the axis is strides[ma] /
     native[ma] and it can be negative -- a reversed read starts at the far
     end and walks down -- so the region runs between the first and last
     index, which is not the same as starts[ma] .. starts[ma] + counts[ma]. */
  {
    ca_size_t step = strides[ma] / native[ma];
    ca_size_t last = starts[ma] + (counts[ma] - 1) * step;
    ca_size_t req_lo = ( last < starts[ma] ) ? last : starts[ma];
    ca_size_t req_hi = (( last < starts[ma] ) ? starts[ma] : last) + 1;
    if ( counts[ma] > 0 && ( req_lo < 0 || req_hi > ca->dim[ma] ) ) {
      rb_raise(rb_eIndexError,
               "CAMeld xfer_stride meld_axis (axis %d) [%lld, %lld) out of range [0, %lld)",
               (int) ma, (long long) req_lo, (long long) req_hi, (long long) ca->dim[ma]);
    }
  }
  for ( i = 0; i < ca->ndim; i++ ) {
    if ( strides[i] != native[i] ) { structural = 0; break; }
  }

  if ( ! structural ) {
    ca_meld_xfer_stride_per_cell(ca, starts, counts, strides, data, dir);
    return;
  }
  if ( ma == 0 ) {
    ca_meld_xfer_stride_ma0(ca, starts, counts, strides, data, dir);
  } else {
    ca_meld_xfer_stride_ma_internal(ca, starts, counts, data, dir);
  }
}

/* ------------------------------------------------------------------- */
/* xfer_all                                                             */
/* ------------------------------------------------------------------- */

/* meld_axis == 0 best path: K contig xfer_all at prefix-sum offsets. */
static void
ca_meld_xfer_all_ma0 (CAMeld *ca, void *data, int dir)
{
  ca_size_t tail_bytes = ca_meld_tail_elements(ca) * ca->bytes;
  char *d = (char *) data;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_xfer_all(ca->parents[k], d + ca->seg_offset[k] * tail_bytes, dir);
  }
}

/* Internal-axis xfer_all: per-parent slab buf + trailing-chunk memcpy.
   Key observation — for meld_axis in [1, ndim-1], the trailing block from
   meld_axis..ndim-1 is contig in BOTH parent and view (the meld cells at
   [seg_lo..seg_hi) × non-meld inner cells all sit contig in view row-major
   as long as outer axes 0..ma-1 are fixed).  So per parent:
     chunk_bytes = p->dim[ma..ndim-1] product * bytes  (= trailing contig run)
     outer_ndim  = ma                                   (axes to odometer)
     Iterate outer axes 0..ma-1, memcpy one chunk_bytes block per iter.
   Falls out of the K contig xfer_alls into the buf, then this loop scatters
   the per-parent slab into its segmented slot in view.
   The naive per-cell odometer that this replaces cost ~2x eager on M2;
   chunked memcpy approaches memcpy bandwidth (eager parity target). */
static void
ca_meld_xfer_all_ma_internal (CAMeld *ca, void *data, int dir)
{
  int8_t   ma = ca->meld_axis;
  int8_t   ndim = ca->ndim;
  ca_size_t bytes = ca->bytes;
  ca_size_t view_stride[CA_RANK_MAX];
  char *d = (char *) data;
  int32_t k;
  int8_t   a;
  ca_size_t s;

  s = bytes;
  for ( a = ndim - 1; a >= 0; a-- ) {
    view_stride[a] = s;
    s *= ca->dim[a];
  }

  for ( k = 0; k < ca->n_parents; k++ ) {
    CArray *p = ca->parents[k];
    ca_size_t seg_lo = ca->seg_offset[k];
    ca_size_t slab_bytes = (ca_size_t) p->elements * bytes;
    ca_size_t chunk_bytes;
    ca_size_t outer_step[CA_RANK_MAX], outer_back[CA_RANK_MAX];
    ca_size_t outer_idx[CA_RANK_MAX];
    volatile VALUE holder;
    char *buf;
    ca_size_t paddr;
    ca_size_t voff;
    int8_t i;

    buf = ALLOCV_N(char, holder, slab_bytes);

    if ( dir == CA_XFER_GET ) {
      ca_xfer_all(p, buf, CA_XFER_GET);
    }

    /* Trailing contig chunk = product(dim[ma..ndim-1]) elements. */
    chunk_bytes = bytes;
    for ( a = ma; a < ndim; a++ ) chunk_bytes *= p->dim[a];

    /* Outer axes 0..ma-1: build step[]/back[] over view row-major. */
    for ( a = 0; a < ma; a++ ) {
      outer_step[a] = view_stride[a];
      outer_back[a] = (p->dim[a] - 1) * view_stride[a];
      outer_idx[a]  = 0;
    }
    paddr = 0;
    voff  = seg_lo * view_stride[ma];   /* meld-axis start in view row-major */

    if ( ma == 0 ) {
      /* Should not reach here (caller dispatches ma==0 to the external
         best path), but guard anyway: one chunk covers the whole parent. */
      if ( dir == CA_XFER_GET ) memcpy(d + voff, buf, chunk_bytes);
      else                      memcpy(buf, d + voff, chunk_bytes);
    }
    else if ( dir == CA_XFER_GET ) {
      while ( 1 ) {
        memcpy(d + voff, buf + paddr, chunk_bytes);
        paddr += chunk_bytes;
        i = ma - 1;
        while ( i >= 0 ) {
          if ( ++outer_idx[i] < p->dim[i] ) { voff += outer_step[i]; break; }
          outer_idx[i] = 0;
          voff -= outer_back[i];
          i--;
        }
        if ( i < 0 ) break;
      }
    }
    else {
      while ( 1 ) {
        memcpy(buf + paddr, d + voff, chunk_bytes);
        paddr += chunk_bytes;
        i = ma - 1;
        while ( i >= 0 ) {
          if ( ++outer_idx[i] < p->dim[i] ) { voff += outer_step[i]; break; }
          outer_idx[i] = 0;
          voff -= outer_back[i];
          i--;
        }
        if ( i < 0 ) break;
      }
    }

    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(p, buf, CA_XFER_PUT);
    }
    ALLOCV_END(holder);
  }
}

static void
ca_meld_func_xfer_all (void *ap, void *data, int dir)
{
  CAMeld *ca = (CAMeld *) ap;
  if ( ca->meld_axis == 0 ) {
    ca_meld_xfer_all_ma0(ca, data, dir);
  } else {
    ca_meld_xfer_all_ma_internal(ca, data, dir);
  }
}

/* ------------------------------------------------------------------- */
/* attach / sync / detach                                               */
/* ------------------------------------------------------------------- */

static void
ca_meld_func_allocate (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_attach(ca->parents[k]);
  }
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_meld_func_attach (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_attach(ca->parents[k]);
  }
  ca->ptr = xmalloc(ca_length(ca));
  ca_meld_func_xfer_all(ca, ca->ptr, CA_XFER_GET);
}

static void
ca_meld_func_sync (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  int32_t k;
  ca_meld_func_xfer_all(ca, ca->ptr, CA_XFER_PUT);
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_sync(ca->parents[k]);
  }
}

static void
ca_meld_func_detach (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  int32_t k;
  xfree(ca->ptr);
  ca->ptr = NULL;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_detach(ca->parents[k]);
  }
}

/* ------------------------------------------------------------------- */
/* fill_data                                                            */
/* ------------------------------------------------------------------- */

static void
ca_meld_func_fill_data (void *ap, void *ptr)
{
  CAMeld *ca = (CAMeld *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_fill(ca->parents[k], ptr);
  }
}

/* ------------------------------------------------------------------- */
/* create_mask (horizontal propagation, mirrors CAStack)                */
/* ------------------------------------------------------------------- */

static void
ca_meld_func_create_mask (void *ap)
{
  CAMeld *ca = (CAMeld *) ap;
  CArray **mask_parents;
  volatile VALUE holder;
  int32_t k;

  mask_parents = ALLOCV_N(CArray *, holder, ca->n_parents);
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_update_mask(ca->parents[k]);
    if ( ! ca->parents[k]->mask ) {
      ca_create_mask(ca->parents[k]);
    }
    mask_parents[k] = ca->parents[k]->mask;
  }
  ca->mask = (CArray *) ca_meld_new(ca->n_parents, mask_parents, ca->meld_axis);
  ALLOCV_END(holder);
}

/* ------------------------------------------------------------------- */
/* fold_stride — always declines                                        */
/* ------------------------------------------------------------------- */

static int
ca_meld_func_fold_stride (void *ap, ca_fold_t *f, void **next_parent)
{
  (void) ap; (void) f; (void) next_parent;
  return 0;   /* fall through to xfer_stride (which handles structural path) */
}

/* ------------------------------------------------------------------- */
/* operation table                                                      */
/* ------------------------------------------------------------------- */

ca_operation_function_t ca_meld_func = {
  -1, /* CA_OBJ_MELD */
  CA_VIEW_ARRAY,
  free_ca_meld,
  ca_meld_func_clone,
  ca_meld_func_allocate,
  ca_meld_func_attach,
  ca_meld_func_sync,
  ca_meld_func_detach,
  ca_meld_func_fill_data,
  ca_meld_func_create_mask,
  ca_meld_func_xfer_index,
  ca_meld_func_xfer_addrs,
  ca_meld_func_fold_stride,
  ca_meld_func_xfer_stride,
  ca_meld_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Ruby surface                                                         */
/* ------------------------------------------------------------------- */

VALUE
rb_ca_meld_new (VALUE parents_ary, int8_t meld_axis)
{
  volatile VALUE obj;
  CAMeld *ca;
  CArray **parents;
  volatile VALUE holder;
  long n, i;

  Check_Type(parents_ary, T_ARRAY);
  n = RARRAY_LEN(parents_ary);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "CAMeld requires at least one parent");
  }
  parents = ALLOCV_N(CArray *, holder, n);
  for ( i = 0; i < n; i++ ) {
    VALUE p = rb_ary_entry(parents_ary, i);
    rb_check_carray_object(p);
    TypedData_Get_Struct(p, CArray, &carray_data_type, parents[i]);
  }
  ca  = ca_meld_new((int32_t) n, parents, meld_axis);
  obj = ca_wrap_struct(ca);
  rb_ivar_set(obj, id_parents, rb_ary_dup(parents_ary));
  rb_ca_set_parent(obj, rb_ary_entry(parents_ary, 0));
  ALLOCV_END(holder);
  return obj;
}

static VALUE
rb_ca_meld_s_allocate (VALUE klass)
{
  CAMeld *ca;
  return TypedData_Make_Struct(klass, CAMeld, &cameld_data_type, ca);
}

static VALUE
rb_ca_meld_initialize_copy (VALUE self, VALUE other)
{
  CAMeld *ca, *cs;
  TypedData_Get_Struct(self,  CAMeld, &cameld_data_type, ca);
  TypedData_Get_Struct(other, CAMeld, &cameld_data_type, cs);
  ca_meld_setup(ca, cs->n_parents, cs->parents, cs->meld_axis);
  return self;
}

/* CAMeld#initialize(list, axis: 0) */
static VALUE
rb_ca_meld_initialize (int argc, VALUE *argv, VALUE self)
{
  CAMeld *ca;
  CArray **parents;
  volatile VALUE holder;
  VALUE list, kwargs, axis_val = Qnil;
  int8_t meld_axis = 0;
  long n, i;

  rb_scan_args(argc, argv, "1:", &list, &kwargs);
  Check_Type(list, T_ARRAY);
  rb_scan_options(kwargs, "axis", &axis_val);
  n = RARRAY_LEN(list);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "CAMeld.new requires at least one parent");
  }
  if ( ! NIL_P(axis_val) ) {
    CArray *ref;
    VALUE first = rb_ary_entry(list, 0);
    rb_check_carray_object(first);
    TypedData_Get_Struct(first, CArray, &carray_data_type, ref);
    meld_axis = (int8_t) rb_ca_normalize_axis_for_ndim(
        NUM2LONG(axis_val), (int) ref->ndim, "CAMeld.new");
  }
  TypedData_Get_Struct(self, CAMeld, &cameld_data_type, ca);
  parents = ALLOCV_N(CArray *, holder, n);
  for ( i = 0; i < n; i++ ) {
    VALUE p = rb_ary_entry(list, i);
    rb_check_carray_object(p);
    TypedData_Get_Struct(p, CArray, &carray_data_type, parents[i]);
  }
  ca_meld_setup(ca, (int32_t) n, parents, meld_axis);
  rb_ivar_set(self, id_parents, rb_ary_dup(list));
  rb_ca_set_parent(self, rb_ary_entry(list, 0));
  ALLOCV_END(holder);
  return self;
}

static VALUE
rb_ca_meld_n_parents (VALUE self)
{
  CAMeld *ca = (CAMeld *) DATA_PTR(self);
  return INT2NUM(ca->n_parents);
}

static VALUE
rb_ca_meld_parents (VALUE self)
{
  return rb_ivar_get(self, id_parents);
}

static VALUE
rb_ca_meld_meld_axis (VALUE self)
{
  CAMeld *ca = (CAMeld *) DATA_PTR(self);
  return INT2NUM((int) ca->meld_axis);
}

/* Ruby-visible segment offsets (K+1 entries, prefix sum along meld_axis). */
static VALUE
rb_ca_meld_seg_offsets (VALUE self)
{
  CAMeld *ca = (CAMeld *) DATA_PTR(self);
  VALUE ary = rb_ary_new_capa(ca->n_parents + 1);
  int32_t k;
  for ( k = 0; k <= ca->n_parents; k++ ) {
    rb_ary_push(ary, LL2NUM((long long) ca->seg_offset[k]));
  }
  return ary;
}

void
Init_ca_obj_meld (void)
{
  /* CAMultiParent layout convention check. */
  if ( offsetof(CAMeld, n_parents) != offsetof(CAMultiParent, n_parents) ||
       offsetof(CAMeld, parents)   != offsetof(CAMultiParent, parents) ) {
    rb_raise(rb_eRuntimeError,
             "CAMeld/CAMultiParent layout mismatch (build error)");
  }

  rb_cCAMeld     = rb_define_class("CAMeld", rb_cCAView);
  rb_cCAMeldMask = rb_define_class("CAMeldMask", rb_cCAMeld);

  CA_OBJ_MELD = ca_install_obj_type(rb_cCAMeld,
                                    &cameld_data_type,
                                    rb_cCAMeldMask,
                                    &cameld_mask_data_type, &ca_meld_func, sizeof(ca_meld_func));
  rb_define_const(rb_cObject, "CA_OBJ_MELD", INT2NUM(CA_OBJ_MELD));

  id_parents = rb_intern("parents");

  rb_define_alloc_func(rb_cCAMeld, rb_ca_meld_s_allocate);
  rb_define_method(rb_cCAMeld, "initialize",
                                      rb_ca_meld_initialize, -1);
  rb_define_method(rb_cCAMeld, "initialize_copy",
                                      rb_ca_meld_initialize_copy, 1);

  rb_define_method(rb_cCAMeld, "n_parents",   rb_ca_meld_n_parents,   0);
  rb_define_method(rb_cCAMeld, "parents",     rb_ca_meld_parents,     0);
  rb_define_method(rb_cCAMeld, "meld_axis",   rb_ca_meld_meld_axis,   0);
  rb_define_method(rb_cCAMeld, "seg_offsets", rb_ca_meld_seg_offsets, 0);
}
