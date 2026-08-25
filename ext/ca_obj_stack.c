/* ---------------------------------------------------------------------------

  CAStack view = an outer-axis stack of K uniform-shape parents.
  shape = (K, *parent_shape); the k_axis dimension is the parent selector,
  the remaining axes follow each parent's row-major layout.

  Design summary:
  - parents must be uniform shape + uniform data_type (= constructor raise)
  - attach materialises via per-parent xfer_all (= K * parent.elements
    bytes peak alloc, caller responsibility)
  - xfer_stride dispatches per-parent over axis-0 range (= partial use →
    partial cost)
  - conditional fold_stride: counts[0] == 1 → fold to that parent;
    multi-parent → fold boundary (decline)
  - create_mask: horizontal propagation (= all parents' roots get
    all-zero mask if any parent has mask) + mask CAStack itself

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_composite_dispatch.h"
#include "ca_obj_face.h"

/* ------------------------------------------------------------------- */
/* TypedData                                                            */
/* ------------------------------------------------------------------- */

static size_t
ca_stack_dsize (const void *ap)
{
  const CAStack *ca = (const CAStack *) ap;
  return sizeof(CAStack)
       + ca->ndim * sizeof(ca_size_t)              /* dim[] */
       + ca->n_parents * sizeof(CArray *);          /* parents[] */
}

const rb_data_type_t castack_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAStack",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_stack_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t castack_mask_data_type = {
    .parent = &castack_data_type,
    .wrap_struct_name = "CAStackMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_stack_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_STACK;

VALUE rb_cCAStack;
VALUE rb_cCAStackMask;

static ID id_parents;

/* ------------------------------------------------------------------- */
/* setup / new / free / clone                                           */
/* ------------------------------------------------------------------- */

/* Validate uniform shape + data_type across parents.  Returns 0 on success,
   raises ArgumentError on a uniform violation (hard reject at the
   constructor; broadcast / coerce is not performed). */
static void
ca_stack_check_uniform (int32_t n_parents, CArray **parents)
{
  CArray *ref;
  int32_t i;
  int8_t k;
  if ( n_parents <= 0 ) {
    rb_raise(rb_eArgError, "CAStack requires at least one parent");
  }
  ref = parents[0];
  for ( i = 1; i < n_parents; i++ ) {
    CArray *p = parents[i];
    if ( p->data_type != ref->data_type ) {
      rb_raise(rb_eArgError,
               "CAStack parents must have uniform data_type "
               "(parent[0]=%d, parent[%d]=%d)",
               ref->data_type, i, p->data_type);
    }
    if ( p->ndim != ref->ndim ) {
      rb_raise(rb_eArgError,
               "CAStack parents must have uniform ndim "
               "(parent[0]=%d, parent[%d]=%d)",
               ref->ndim, i, p->ndim);
    }
    for ( k = 0; k < ref->ndim; k++ ) {
      if ( p->dim[k] != ref->dim[k] ) {
        rb_raise(rb_eArgError,
                 "CAStack parents must have uniform shape "
                 "(mismatch at axis %d: parent[0]=%lld, parent[%d]=%lld)",
                 (int) k,
                 (long long) ref->dim[k],
                 (int) i,
                 (long long) p->dim[k]);
      }
    }
    if ( p->bytes != ref->bytes ) {
      rb_raise(rb_eArgError,
               "CAStack parents must have uniform bytes "
               "(parent[0]=%lld, parent[%d]=%lld)",
               (long long) ref->bytes, (int) i, (long long) p->bytes);
    }
  }
}

/* One-level strip of a Face VALUE to its storage-side parent (non-Face as-is).
   Used to keep the @parent GC/`.parent` ivar in step with the pre-stripped C
   parents so the Ruby-visible chain of a stacked Face is single-Face too. */
static VALUE
ca_stack_face_parent1 (VALUE v)
{
  CArray *c;
  TypedData_Get_Struct(v, CArray, &carray_data_type, c);
  return ca_is_face(c) ? rb_ca_parent(v) : v;
}

int
ca_stack_setup_with_axis (CAStack *ca, int32_t n_parents, CArray **parents,
                          int8_t k_axis)
{
  CArray *ref;
  int32_t i;
  int8_t  a;

  /* §8.3 / MEMO_FACE_DOUBLE_LIFT §15.3: pre-strip Face parents one level to
     storage so a stacked Face lifts to a single-Face chain
     (CATime[CAStack[entity, ...]]) instead of a Face on top of Face parents.
     One level (not a full walk) preserves any distinct Face a parent stacked
     underneath.  A Face is storage-transparent, so stacking over storage reads
     the same bytes; the lifted top Face (rb_ca_stack_s_new) carries the
     identity.  The @parents accessor keeps the originals (set by the callers). */
  for ( i = 0; i < n_parents; i++ ) {
    if ( ca_is_face(parents[i]) ) {
      parents[i] = CAVIEW(parents[i])->parent;
    }
  }

  ca_stack_check_uniform(n_parents, parents);
  ref = parents[0];

  if ( k_axis < 0 || k_axis > ref->ndim ) {
    rb_raise(rb_eArgError,
             "CAStack k_axis %d out of range [0, %d]",
             (int) k_axis, (int) ref->ndim);
  }

  ca->obj_type  = CA_OBJ_STACK;
  ca->data_type = ref->data_type;
  ca->flags     = CA_FLAG_MULTI_PARENTS;   /* fold-over-parents in generic code */
  ca->ndim      = ref->ndim + 1;
  ca->bytes     = ref->bytes;
  ca->elements  = (ca_size_t) n_parents * ref->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;

  ca->parent    = ref;        /* CAView base field (= parents[0]) */
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->n_parents = n_parents;
  ca->parents   = ALLOC_N(CArray *, n_parents);
  for ( i = 0; i < n_parents; i++ ) {
    ca->parents[i] = parents[i];
  }
  ca->k_axis    = k_axis;

  ca->dim = ALLOC_N(ca_size_t, ca->ndim);
  /* dim[a] = parent.dim[a]   for a < k_axis
     dim[k_axis] = K (= n_parents)
     dim[a] = parent.dim[a-1] for a > k_axis */
  for ( a = 0; a < k_axis; a++ )            ca->dim[a] = ref->dim[a];
  ca->dim[k_axis] = n_parents;
  for ( a = k_axis + 1; a < ca->ndim; a++ ) ca->dim[a] = ref->dim[a - 1];

  /* mask: lazy; horizontal propagation triggers on first mask access. */
  return 0;
}

int
ca_stack_setup (CAStack *ca, int32_t n_parents, CArray **parents)
{
  return ca_stack_setup_with_axis(ca, n_parents, parents, 0);
}

CAStack *
ca_stack_new_with_axis (int32_t n_parents, CArray **parents, int8_t k_axis)
{
  CAStack *ca = ALLOC(CAStack);
  ca_stack_setup_with_axis(ca, n_parents, parents, k_axis);
  return ca;
}

CAStack *
ca_stack_new (int32_t n_parents, CArray **parents)
{
  return ca_stack_new_with_axis(n_parents, parents, 0);
}

static void
free_ca_stack (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->parents);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_stack_func_clone (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  return ca_stack_new_with_axis(ca->n_parents, ca->parents, ca->k_axis);
}

/* ------------------------------------------------------------------- */
/* xfer_index                                                           */
/* ------------------------------------------------------------------- */

/* view[..., k at k_axis, ...] = parents[k][parent_idx]
   where parent_idx = idx[] with the k_axis slot removed. */
static void
ca_stack_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAStack *ca = (CAStack *) ap;
  int8_t   k_axis = ca->k_axis;
  ca_size_t k = idx[k_axis];
  if ( k < 0 || k >= ca->n_parents ) {
    rb_raise(rb_eIndexError, "CAStack k-axis (axis %d) index %lld out of range [0, %d)",
             (int) k_axis, (long long) k, (int) ca->n_parents);
  }
  if ( k_axis == 0 ) {
    /* Fast path: parent_idx = idx[1..ndim-1]; pass idx+1 directly. */
    ca_xfer_index(ca->parents[k], idx + 1, data, dir);
    return;
  }
  /* General case: build parent_idx by removing the k_axis slot. */
  {
    ca_size_t pidx[CA_RANK_MAX];
    int8_t a, pndim = ca->ndim - 1;
    for ( a = 0; a < k_axis; a++ )       pidx[a] = idx[a];
    for ( a = k_axis; a < pndim; a++ )   pidx[a] = idx[a + 1];
    ca_xfer_index(ca->parents[k], pidx, data, dir);
  }
}

/* ------------------------------------------------------------------- */
/* xfer_addrs (batched)                                                 */
/* ------------------------------------------------------------------- */

/* Per-addr: decompose addr -> (k, intra_addr) where k = addr / parent_elements
   and intra_addr = addr % parent_elements.  Group by k for batched parent
   dispatch.  Simple K-pass implementation: scan once per parent; OK for
   typical K (= small to medium).  Hot K cases can opt into a single-pass
   bucket sort if needed. */
static void
ca_stack_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CAStack *ca = (CAStack *) ap;
  int8_t   k_axis = ca->k_axis;
  ca_size_t parent_elements = ca->parents[0]->elements;
  ca_size_t bytes = ca->bytes;
  ca_size_t *paddrs;
  char     *pdata, *cdata = (char *) data;
  volatile VALUE holder1, holder2;
  ca_size_t i;
  int32_t   k;

  paddrs = ALLOCV_N(ca_size_t, holder1, n);
  pdata  = ALLOCV_N(char, holder2, n * bytes);

  if ( k_axis == 0 ) {
    /* Fast path: addr = k * parent_elements + parent_addr (row-major over
       view shape with K at axis 0). */
    for ( k = 0; k < ca->n_parents; k++ ) {
      ca_size_t m = 0;
      for ( i = 0; i < n; i++ ) {
        if ( addrs[i] / parent_elements == (ca_size_t) k ) {
          paddrs[m] = addrs[i] % parent_elements;
          if ( dir == CA_XFER_PUT ) {
            memcpy(pdata + m * bytes, cdata + i * bytes, bytes);
          }
          m++;
        }
      }
      if ( m > 0 ) {
        ca_xfer_addrs(ca->parents[k], m, paddrs, pdata, dir);
        if ( dir == CA_XFER_GET ) {
          ca_size_t mm = 0;
          for ( i = 0; i < n; i++ ) {
            if ( addrs[i] / parent_elements == (ca_size_t) k ) {
              memcpy(cdata + i * bytes, pdata + mm * bytes, bytes);
              mm++;
            }
          }
        }
      }
    }
  }
  else {
    /* General case: decode addrs[i] in view row-major to extract
       k = vidx[k_axis] and the parent's row-major address from the
       remaining axes. */
    int8_t pndim = ca->ndim - 1;
    ca_size_t view_div[CA_RANK_MAX];   /* row-major divisor per view axis */
    ca_size_t parent_mul[CA_RANK_MAX]; /* row-major multiplier per parent axis */
    ca_size_t s;
    int8_t a;
    s = 1;
    for ( a = ca->ndim - 1; a >= 0; a-- ) { view_div[a] = s; s *= ca->dim[a]; }
    s = 1;
    for ( a = pndim - 1; a >= 0; a-- ) {
      parent_mul[a] = s;
      s *= ca->parents[0]->dim[a];
    }

    for ( k = 0; k < ca->n_parents; k++ ) {
      ca_size_t m = 0;
      for ( i = 0; i < n; i++ ) {
        ca_size_t addr = addrs[i];
        ca_size_t vidx_k = (addr / view_div[k_axis]) % ca->dim[k_axis];
        if ( vidx_k != (ca_size_t) k ) continue;
        {
          ca_size_t paddr = 0;
          int8_t b;
          for ( b = 0; b < k_axis; b++ ) {
            ca_size_t v = (addr / view_div[b]) % ca->dim[b];
            paddr += v * parent_mul[b];
          }
          for ( b = k_axis + 1; b < ca->ndim; b++ ) {
            ca_size_t v = (addr / view_div[b]) % ca->dim[b];
            paddr += v * parent_mul[b - 1];
          }
          paddrs[m] = paddr;
        }
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
            ca_size_t vidx_k = (addr / view_div[k_axis]) % ca->dim[k_axis];
            if ( vidx_k != (ca_size_t) k ) continue;
            memcpy(cdata + i * bytes, pdata + mm * bytes, bytes);
            mm++;
          }
        }
      }
    }
    (void) parent_elements;
  }
  ALLOCV_END(holder2);
  ALLOCV_END(holder1);
}

/* ------------------------------------------------------------------- */
/* xfer_stride: K-fold per-parent dispatch over axis-0 range            */
/* ------------------------------------------------------------------- */

/* Contract (= CATile pattern): caller's `strides[]` are the chain-composed
   strides through root's byte space (= the result of ca_stride_compose_to_root
   in CAStride.xfer_stride).  starts[] is in CAStack-axis order (= addr2index
   of composed_base); counts[]/strides[] are in OUTPUT-axis order.

   Three paths:
   - Structural (strides[i] == native[i] for all i): per-parent K-fold over
     the request's k_axis range.  k_axis=0 = each parent contig in dst (zero
     copy slot); k_axis!=0 = per-parent xfer_stride into a slab buf, then
     scatter/gather between buf and the view-strided dst positions.
   - Reloc (permutation that only moved K from view axis k_axis to output
     position p, non-K axes preserve relative order): per (leading + K)
     position dispatch.  K-innermost (p == ndim-1) escapes per-cell via the
     parent's xfer_index; otherwise per-parent inner-block xfer_stride.
   - Per-cell fallback via xfer_index. */
static void
ca_stack_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                           ca_size_t *strides, void *data, int dir)
{
  CAStack *ca = (CAStack *) ap;
  int8_t   k_axis = ca->k_axis;
  int8_t   pndim = ca->ndim - 1;
  ca_size_t native[CA_RANK_MAX], dstride[CA_RANK_MAX];
  ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
  ca_size_t k, s;
  int8_t    i;
  int       structural = 1;
  char     *d = (char *) data;

  /* CAStack's native row-major byte strides over its full shape. */
  s = ca->bytes;
  for ( i = ca->ndim - 1; i >= 0; i-- ) { native[i] = s; s *= ca->dim[i]; }

  /* Parent's native (source) byte strides over its own row-major shape. */
  s = ca->bytes;
  for ( i = pndim - 1; i >= 0; i-- ) {
    pstrides[i] = s;
    s *= ca->parents[0]->dim[i];
  }

  /* Structural iff strides[k] == native[k] for all k. */
  for ( i = 0; i < ca->ndim; i++ ) {
    if ( strides[i] != native[i] ) { structural = 0; break; }
  }

  if ( structural ) {
    ca_size_t k_lo = starts[k_axis];
    ca_size_t k_hi = starts[k_axis] + counts[k_axis];
    if ( k_lo < 0 || k_hi > ca->n_parents ) {
      rb_raise(rb_eIndexError,
               "CAStack xfer_stride k-axis (axis %d) [%lld, %lld) out of range [0, %d)",
               (int) k_axis, (long long) k_lo, (long long) k_hi, (int) ca->n_parents);
    }

    /* dst row-major byte strides over output counts[]. */
    s = ca->bytes;
    for ( i = ca->ndim - 1; i >= 0; i-- ) { dstride[i] = s; s *= counts[i]; }

    /* pstarts/pcounts = starts/counts with the k_axis slot removed. */
    for ( i = 0; i < pndim; i++ ) {
      int8_t v = (i < k_axis) ? i : (i + 1);
      pstarts[i] = starts[v];
      pcounts[i] = counts[v];
    }

    if ( k_axis == 0 ) {
      /* Each parent's row-major output is a contig slot of dstride[0] bytes
         in dst -- zero copy. */
      for ( k = k_lo; k < k_hi; k++ ) {
        char *slot = d + (k - k_lo) * dstride[0];
        ca_xfer_stride(ca->parents[k], pstarts, pcounts, pstrides, slot, dir);
      }
      return;
    }

    /* k_axis != 0: parent's row-major output of size slab_elements * bytes
       does not fit contig in dst because the K-stride sits in the middle of
       the dst row-major flow.  Per-parent: deliver into a slab buf, then
       walk parent_idx row-major to scatter/gather to/from dst at the
       view-strided positions. */
    {
      ca_size_t slab_bytes = ca->bytes;
      ca_size_t inner_dim[CA_RANK_MAX];
      volatile VALUE holder;
      char *buf;
      int8_t a;

      for ( i = 0; i < pndim; i++ ) {
        inner_dim[i] = pcounts[i];
        slab_bytes *= pcounts[i];
      }
      buf = ALLOCV_N(char, holder, slab_bytes);

      for ( k = k_lo; k < k_hi; k++ ) {
        ca_size_t k_off = (k - k_lo) * dstride[k_axis];
        if ( dir == CA_XFER_GET ) {
          ca_xfer_stride(ca->parents[k], pstarts, pcounts, pstrides, buf, CA_XFER_GET);
        }
        if ( pndim == 0 ) {
          /* parent is scalar-shaped (1 element). */
          if ( dir == CA_XFER_GET ) memcpy(d + k_off, buf, ca->bytes);
          else                      memcpy(buf, d + k_off, ca->bytes);
        }
        else {
          ca_size_t pidx[CA_RANK_MAX];
          ca_size_t paddr = 0;
          for ( a = 0; a < pndim; a++ ) pidx[a] = 0;
          while ( 1 ) {
            ca_size_t voff = k_off;
            for ( a = 0; a < k_axis; a++ )     voff += pidx[a] * dstride[a];
            for ( a = k_axis; a < pndim; a++ ) voff += pidx[a] * dstride[a + 1];
            if ( dir == CA_XFER_GET ) memcpy(d + voff, buf + paddr, ca->bytes);
            else                      memcpy(buf + paddr, d + voff, ca->bytes);
            paddr += ca->bytes;
            i = pndim - 1;
            while ( i >= 0 ) {
              if ( ++pidx[i] < inner_dim[i] ) break;
              pidx[i] = 0;
              i--;
            }
            if ( i < 0 ) break;
          }
        }
        if ( dir == CA_XFER_PUT ) {
          ca_xfer_stride(ca->parents[k], pstarts, pcounts, pstrides, buf, CA_XFER_PUT);
        }
      }
      ALLOCV_END(holder);
    }
    return;
  }

  /* Non-structural: try reloc fast path.  The request is a permutation that
     moved K from view axis k_axis to output position p, with the non-K axes
     preserving their relative order.  Detection: native[k_axis] appears in
     strides[] at position p; the remaining strides[] equal native[0..ndim-1]
     with native[k_axis] removed, in order. */
  {
    int8_t p = -1;
    int    reloc = 1;
    for ( i = 0; i < ca->ndim; i++ ) {
      if ( strides[i] == native[k_axis] ) { p = i; break; }
    }
    if ( p < 0 ) {
      reloc = 0;
    }
    else {
      /* non_K_native[j] = native of the j-th non-K view axis (in view order)
         = native[j] if j < k_axis else native[j + 1].
         For output position i != p, strides[i] should equal
         non_K_native[i if i < p else i - 1]. */
      for ( i = 0; i < ca->ndim; i++ ) {
        int8_t j, v;
        if ( i == p ) continue;
        j = (i < p) ? i : (i - 1);
        v = (j < k_axis) ? j : (j + 1);
        if ( strides[i] != native[v] ) { reloc = 0; break; }
      }
    }
    if ( reloc ) {
      ca_size_t kk_lo = starts[k_axis];
      ca_size_t kk_hi = starts[k_axis] + counts[p];
      ca_size_t odo[CA_RANK_MAX];
      int8_t    a;
      if ( kk_lo < 0 || kk_hi > ca->n_parents ) {
        rb_raise(rb_eIndexError,
                 "CAStack xfer_stride k-axis [%lld, %lld) out of range [0, %d)",
                 (long long) kk_lo, (long long) kk_hi, (int) ca->n_parents);
      }
      if ( p == ca->ndim - 1 ) {
        /* K innermost: per-cell via the parent's xfer_index directly, escaping
           the CAStack-level addr2index dispatch hop in the per-cell fallback. */
        ca_size_t pidx[CA_RANK_MAX], doff = 0;
        for ( i = 0; i < ca->ndim; i++ ) odo[i] = 0;
        while ( 1 ) {
          ca_size_t k2 = starts[k_axis] + odo[p];
          for ( a = 0; a < pndim; a++ ) {
            int8_t v = (a < k_axis) ? a : (a + 1);
            pidx[a] = starts[v] + odo[a];
          }
          ca_xfer_index(ca->parents[k2], pidx, d + doff, dir);
          doff += ca->bytes;
          i = ca->ndim - 1;
          while ( i >= 0 ) { if ( ++odo[i] < counts[i] ) break; odo[i] = 0; i--; }
          if ( i < 0 ) break;
        }
        return;
      }
      /* dst row-major byte strides over output counts. */
      s = ca->bytes;
      for ( i = ca->ndim - 1; i >= 0; i-- ) { dstride[i] = s; s *= counts[i]; }
      for ( i = 0; i <= p; i++ ) odo[i] = 0;
      while ( 1 ) {
        ca_size_t k2 = starts[k_axis] + odo[p];
        ca_size_t doff = 0;
        for ( i = 0; i <= p; i++ ) doff += odo[i] * dstride[i];
        for ( a = 0; a < pndim; a++ ) {
          int8_t v = (a < k_axis) ? a : (a + 1);
          if ( a < p ) {
            pstarts[a] = starts[v] + odo[a];
            pcounts[a] = 1;
          }
          else {
            pstarts[a] = starts[v];
            pcounts[a] = counts[a + 1];
          }
        }
        ca_xfer_stride(ca->parents[k2], pstarts, pcounts, pstrides, d + doff, dir);
        i = p;
        while ( i >= 0 ) { if ( ++odo[i] < counts[i] ) break; odo[i] = 0; i--; }
        if ( i < 0 ) break;
      }
      return;
    }
  }

  /* Per-cell fallback via xfer_index. */
  {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for ( i = 0; i < ca->ndim; i++ ) base += starts[i] * native[i];
    for ( i = 0; i < ca->ndim; i++ ) idx[i] = 0;
    while ( 1 ) {
      ca_size_t toff = base, vidx[CA_RANK_MAX];
      for ( i = 0; i < ca->ndim; i++ ) toff += idx[i] * strides[i];
      ca_addr2index((CArray *) ca, toff / ca->bytes, vidx);
      ca_stack_func_xfer_index(ca, vidx, d + doff, dir);
      doff += ca->bytes;
      i = ca->ndim - 1;
      while ( i >= 0 ) { if ( ++idx[i] < counts[i] ) break; idx[i] = 0; i--; }
      if ( i < 0 ) break;
    }
  }
}

/* ------------------------------------------------------------------- */
/* xfer_all: K-fold over all parents                                    */
/* ------------------------------------------------------------------- */

/* gather/scatter the entire view buffer (= row-major contig over the
   view's own shape).
   - k_axis == 0: each parent slot occupies parent.elements * bytes
     contiguous bytes in dst; deliver via parent.xfer_all directly.
   - k_axis != 0: per-parent contiguous read into a temp buffer, then
     scattered-write to dst at view row-major positions.  This is the
     correctness path (per-parent contig-read / scattered-write), not a
     perf-optimised one. */
static void
ca_stack_func_xfer_all (void *ap, void *data, int dir)
{
  CAStack *ca = (CAStack *) ap;
  int8_t  k_axis = ca->k_axis;
  ca_size_t bytes = ca->bytes;
  char *d = (char *) data;
  int32_t k;

  if ( k_axis == 0 ) {
    ca_size_t parent_bytes_total = ca->parents[0]->elements * bytes;
    for ( k = 0; k < ca->n_parents; k++ ) {
      ca_xfer_all(ca->parents[k], d + k * parent_bytes_total, dir);
    }
    return;
  }

  {
    int8_t pndim = ca->ndim - 1;
    ca_size_t parent_elements = ca->parents[0]->elements;
    ca_size_t view_stride[CA_RANK_MAX];  /* byte strides over view row-major */
    ca_size_t parent_dim[CA_RANK_MAX];
    volatile VALUE holder;
    char *buf;
    ca_size_t s;
    int8_t a;

    s = bytes;
    for ( a = ca->ndim - 1; a >= 0; a-- ) {
      view_stride[a] = s;
      s *= ca->dim[a];
    }
    for ( a = 0; a < pndim; a++ ) parent_dim[a] = ca->parents[0]->dim[a];

    buf = ALLOCV_N(char, holder, parent_elements * bytes);

    /* Per-parent axis step/back tables for incremental voff update.
       parent axis a maps to view axis v = a if a < k_axis else a + 1;
       step[a] = the dst byte stride contributed by parent axis a;
       back[a] = (parent_dim[a] - 1) * step[a] = amount to subtract on wrap.
       These are independent of k, so hoist outside the per-parent loop. */
    {
      ca_size_t step[CA_RANK_MAX];
      ca_size_t back[CA_RANK_MAX];
      for ( a = 0; a < pndim; a++ ) {
        int8_t v = (a < k_axis) ? a : (a + 1);
        step[a] = view_stride[v];
        back[a] = (parent_dim[a] - 1) * step[a];
      }

      for ( k = 0; k < ca->n_parents; k++ ) {
        ca_size_t k_off = (ca_size_t) k * view_stride[k_axis];
        ca_size_t pidx[CA_RANK_MAX];
        ca_size_t paddr_bytes = 0;
        ca_size_t voff = k_off;
        int8_t i;

        if ( dir == CA_XFER_GET ) {
          ca_xfer_all(ca->parents[k], buf, CA_XFER_GET);
        }

        for ( a = 0; a < pndim; a++ ) pidx[a] = 0;

        if ( pndim == 0 ) {
          /* parent is scalar-shaped (= 1 element); single cell at k_off. */
          if ( dir == CA_XFER_GET ) memcpy(d + k_off, buf, bytes);
          else                      memcpy(buf, d + k_off, bytes);
        }
        else if ( dir == CA_XFER_GET ) {
          /* dir-hoisted GET inner loop, incremental voff. */
          while ( 1 ) {
            memcpy(d + voff, buf + paddr_bytes, bytes);
            paddr_bytes += bytes;
            i = pndim - 1;
            while ( i >= 0 ) {
              if ( ++pidx[i] < parent_dim[i] ) { voff += step[i]; break; }
              pidx[i] = 0;
              voff -= back[i];
              i--;
            }
            if ( i < 0 ) break;
          }
        }
        else {
          /* dir-hoisted PUT inner loop, incremental voff. */
          while ( 1 ) {
            memcpy(buf + paddr_bytes, d + voff, bytes);
            paddr_bytes += bytes;
            i = pndim - 1;
            while ( i >= 0 ) {
              if ( ++pidx[i] < parent_dim[i] ) { voff += step[i]; break; }
              pidx[i] = 0;
              voff -= back[i];
              i--;
            }
            if ( i < 0 ) break;
          }
        }

        if ( dir == CA_XFER_PUT ) {
          ca_xfer_all(ca->parents[k], buf, CA_XFER_PUT);
        }
      }
    }
    ALLOCV_END(holder);
  }
}

/* ------------------------------------------------------------------- */
/* attach / sync / detach (materialise via xfer_all)                    */
/* ------------------------------------------------------------------- */

static void
ca_stack_func_allocate (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_attach(ca->parents[k]);
  }
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_stack_func_attach (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_attach(ca->parents[k]);
  }
  ca->ptr = xmalloc(ca_length(ca));
  ca_stack_func_xfer_all(ca, ca->ptr, CA_XFER_GET);
}

static void
ca_stack_func_sync (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  int32_t k;
  ca_stack_func_xfer_all(ca, ca->ptr, CA_XFER_PUT);
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_sync(ca->parents[k]);
  }
}

static void
ca_stack_func_detach (void *ap)
{
  CAStack *ca = (CAStack *) ap;
  int32_t k;
  xfree(ca->ptr);
  ca->ptr = NULL;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_detach(ca->parents[k]);
  }
}

/* ------------------------------------------------------------------- */
/* fill_data: K-fold per-parent fill                                    */
/* ------------------------------------------------------------------- */

static void
ca_stack_func_fill_data (void *ap, void *ptr)
{
  CAStack *ca = (CAStack *) ap;
  int32_t k;
  for ( k = 0; k < ca->n_parents; k++ ) {
    ca_fill(ca->parents[k], ptr);
  }
}

/* ------------------------------------------------------------------- */
/* create_mask: horizontal propagation                                  */
/* ------------------------------------------------------------------- */

/* All parents' roots gain all-zero mask (if not already), then build
   mask CAStack from the K parent mask CArrays.  Self-similar (= CAStack
   re-used as its own mask class). */
static void
ca_stack_func_create_mask (void *ap)
{
  CAStack *ca = (CAStack *) ap;
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
  /* Build the mask stack with the parent's k_axis from the start so its
     dim[] is laid out for that axis.  (Patching ->k_axis after a default
     ca_stack_new leaves dim[] computed for k_axis 0 — an inconsistent
     geometry that mis-shapes arr.mask and breaks the structural
     xfer_stride k-range check when k_axis != 0.) */
  ca->mask = (CArray *) ca_stack_new_with_axis(ca->n_parents, mask_parents,
                                               ca->k_axis);
  ALLOCV_END(holder);
}

/* ------------------------------------------------------------------- */
/* fold_stride: conditional participation                               */
/* ------------------------------------------------------------------- */

/* Fold to a single parent iff the request's byte box lies entirely within one
   parent, then rebase into that parent's space and continue the compose there.

   Testing only f->counts[0] == 1 is WRONG for a permuting chain: after a
   transpose the K axis (native stride = parent_bytes_total) is no longer at
   axis 0, so a size-1 leading PARENT axis (counts[0] == 1) would spuriously
   fold a genuinely multi-parent request down to one parent -- silent data loss
   (observed: t.transpose(1,0,2)[2..2, 0..3, 2..4]).  Box containment is
   order-independent and correct regardless of where the K axis ended up. */
static int
ca_stack_func_fold_stride (void *ap, ca_fold_t *f, void **next_parent)
{
  CAStack  *ca = (CAStack *) ap;
  ca_size_t pbt = ca->parents[0]->elements * ca->bytes;
  ca_size_t lo = f->base, hi = f->base;
  ca_size_t k;
  int8_t    i;

  /* k_axis != 0: parent byte blocks are interleaved (not contig in view
     buffer), so the byte-box containment check and the size-1 K-axis
     degeneration below would require detecting the K-axis contribution
     inside an arbitrary stride composition -- not just probing for the
     parent_bytes_total stride at axis 0.  Decline fold; the caller falls
     through to CAStack.xfer_stride (k_axis-aware), which still delivers
     correct (if non-folded) per-parent dispatch. */
  if ( ca->k_axis != 0 ) return 0;

  for ( i = 0; i < f->ndim; i++ ) {
    ca_size_t span = (f->counts[i] - 1) * f->strides[i];
    if ( span >= 0 ) hi += span; else lo += span;   /* negative stride extends lo */
  }
  if ( lo < 0 ) return 0;
  k = lo / pbt;
  if ( k < 0 || k >= ca->n_parents ) return 0;
  if ( hi >= (k + 1) * pbt ) return 0;              /* box spans >1 parent */

  f->base -= k * pbt;
  for ( i = 0; i < f->ndim; i++ ) {                 /* degenerate the (size-1) K axis */
    if ( f->strides[i] == pbt ) f->strides[i] = 0;
  }
  *next_parent = (void *) ca->parents[k];
  return 1;
}

/* ------------------------------------------------------------------- */
/* operation table                                                      */
/* ------------------------------------------------------------------- */

ca_operation_function_t ca_stack_func = {
  -1, /* CA_OBJ_STACK */
  CA_VIEW_ARRAY,
  free_ca_stack,
  ca_stack_func_clone,
  ca_stack_func_allocate,
  ca_stack_func_attach,
  ca_stack_func_sync,
  ca_stack_func_detach,
  ca_stack_func_fill_data,
  ca_stack_func_create_mask,
  ca_stack_func_xfer_index,
  ca_stack_func_xfer_addrs,
  ca_stack_func_fold_stride,
  ca_stack_func_xfer_stride,
  ca_stack_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Ruby surface                                                         */
/* ------------------------------------------------------------------- */

/* Build the raw CAStack VALUE from a Ruby array of CArray VALUEs.

   Storage-level construction: no Face awareness, no promote/check
   beyond ca_stack_check_uniform (data_type + shape uniformity).
   Returns a fresh CAStack VALUE (not a Face-wrapped lift).

   The Face dance (= homogeneity check + lift) lives in the high-level
   Ruby `CArray.stack` defined in lib/carray/compose.rb, which calls
   `CArray.promote_list` for the homogeneity + state / portability
   verdict and `ca.face_lift(face_parent)` (= rb_ca_face_lift_method)
   for the final re-wrap.  Keeping CAStack constructor raw-only means
   `CAStack.new(list, axis:)` follows the Class#new contract (= always
   returns a CAStack), and the lift becomes a transparent Ruby-side
   step rather than a hidden C dispatch surprise. */
VALUE
rb_ca_stack_new_with_axis (VALUE parents_ary, int8_t k_axis)
{
  volatile VALUE obj;
  CAStack *ca;
  CArray **parents;
  volatile VALUE holder;
  long n, i;

  Check_Type(parents_ary, T_ARRAY);
  n = RARRAY_LEN(parents_ary);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "CAStack requires at least one parent");
  }
  parents = ALLOCV_N(CArray *, holder, n);
  for ( i = 0; i < n; i++ ) {
    VALUE p = rb_ary_entry(parents_ary, i);
    rb_check_carray_object(p);
    TypedData_Get_Struct(p, CArray, &carray_data_type, parents[i]);
  }
  ca  = ca_stack_new_with_axis((int32_t) n, parents, k_axis);
  obj = ca_wrap_struct(ca);
  rb_ivar_set(obj, id_parents, rb_ary_dup(parents_ary));  /* GC anchor */
  rb_ca_set_parent(obj, ca_stack_face_parent1(rb_ary_entry(parents_ary, 0)));  /* CAView base (Face-stripped, matches C ->parent) */
  ALLOCV_END(holder);
  return obj;
}

VALUE
rb_ca_stack_new (VALUE parents_ary)
{
  return rb_ca_stack_new_with_axis(parents_ary, 0);
}

/* CArray.stack class method + CArray#stack instance method are defined
   in lib/carray/compose.rb as the high-level Ruby surface that delegates
   to CAStack.new after promote_list + (optional) face_lift.  CAStack.new
   is the canonical low-level constructor; promote_list handles Face. */

static VALUE
rb_ca_stack_s_allocate (VALUE klass)
{
  CAStack *ca;
  return TypedData_Make_Struct(klass, CAStack, &castack_data_type, ca);
}

static VALUE
rb_ca_stack_initialize_copy (VALUE self, VALUE other)
{
  CAStack *ca, *cs;
  TypedData_Get_Struct(self,  CAStack, &castack_data_type, ca);
  TypedData_Get_Struct(other, CAStack, &castack_data_type, cs);
  ca_stack_setup_with_axis(ca, cs->n_parents, cs->parents, cs->k_axis);
  return self;
}

/* CAStack#initialize(list, axis: 0) -- the OO constructor entry.

   Class#new chain: allocate -> initialize.  Allocate produces an empty
   TypedData-wrapped CAStack struct; we set up the parents[] / k_axis /
   dim[] in this method.

   Raw-only: no Face homogeneity check, no lift.  The lift is performed
   by the high-level CArray.stack Ruby method (= lib/carray/compose.rb)
   which calls CAStack.new then ca.face_lift(face_parent). */
static VALUE
rb_ca_stack_initialize (int argc, VALUE *argv, VALUE self)
{
  CAStack *ca;
  CArray **parents;
  volatile VALUE holder;
  VALUE list, kwargs, axis_val = Qnil;
  int8_t k_axis = 0;
  long n, i;

  rb_scan_args(argc, argv, "1:", &list, &kwargs);
  Check_Type(list, T_ARRAY);
  rb_scan_options(kwargs, "axis", &axis_val);
  n = RARRAY_LEN(list);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "CAStack.new requires at least one parent");
  }
  if ( ! NIL_P(axis_val) ) {
    /* Resolve k_axis against the first parent's ndim (= insertion position
       range [0, parent_ndim], i.e. half-open [0, parent_ndim + 1)). */
    CArray *ref;
    VALUE first = rb_ary_entry(list, 0);
    rb_check_carray_object(first);
    TypedData_Get_Struct(first, CArray, &carray_data_type, ref);
    k_axis = (int8_t) rb_ca_normalize_axis_for_ndim(
        NUM2LONG(axis_val), (int) ref->ndim + 1, "CAStack.new");
  }
  TypedData_Get_Struct(self, CAStack, &castack_data_type, ca);
  parents = ALLOCV_N(CArray *, holder, n);
  for ( i = 0; i < n; i++ ) {
    VALUE p = rb_ary_entry(list, i);
    rb_check_carray_object(p);
    TypedData_Get_Struct(p, CArray, &carray_data_type, parents[i]);
  }
  ca_stack_setup_with_axis(ca, (int32_t) n, parents, k_axis);
  rb_ivar_set(self, id_parents, rb_ary_dup(list));  /* GC anchor */
  rb_ca_set_parent(self, ca_stack_face_parent1(rb_ary_entry(list, 0)));  /* CAView base (Face-stripped, matches C ->parent) */
  ALLOCV_END(holder);
  return self;
}

/* CAStack.new(list, axis: 0) -- singleton override of Class#new that
   layers Face-aware semantics on top of the raw allocate + initialize
   chain.

   For a homogeneous Face list (= all same Face class with compatible
   state + portable):
     - the raw CAStack is built via rb_obj_alloc + rb_obj_call_init
       (= bypasses the Class#new dispatcher to avoid recursion into
       this method)
     - then ca_face_lift re-wraps the result as the same Face class,
       carrying state from list[0]
   For non-Face / mixed / heterogeneous lists, returns the raw CAStack
   directly (= same result as the inherited Class#new chain).

   Replaces the Ruby-level CAStack.new override in lib/carray/compose.rb
   (= used alias_method :__new_raw__, :new + class << self def new).
   Consolidating in C removes the dispatch trick and the per-call
   rb_funcall hops to face_state_portable? / face_state_compatible?. */
static VALUE
rb_ca_stack_s_new (int argc, VALUE *argv, VALUE klass)
{
  VALUE list, kwargs;
  long n, i;
  int  all_face = 1;
  VALUE face_class = Qnil;
  CArray *ref_face = NULL;
  VALUE obj;

  rb_scan_args(argc, argv, "1:", &list, &kwargs);
  Check_Type(list, T_ARRAY);
  n = RARRAY_LEN(list);
  if ( n <= 0 ) {
    rb_raise(rb_eArgError, "CAStack.new requires at least one parent");
  }

  /* Inspect Face homogeneity in one pass.  Bail to non-Face path as
     soon as a non-Face or class-mismatched element is seen. */
  for ( i = 0; i < n; i++ ) {
    VALUE p = rb_ary_entry(list, i);
    CArray *ca;
    rb_check_carray_object(p);
    TypedData_Get_Struct(p, CArray, &carray_data_type, ca);
    if ( !ca_is_face(ca) ) { all_face = 0; break; }
    if ( i == 0 ) {
      face_class = rb_obj_class(p);
      ref_face   = ca;
    } else if ( rb_obj_class(p) != face_class ) {
      all_face = 0; break;
    }
  }

  /* Allocate + initialize raw CAStack.  rb_obj_alloc calls the
     TypedData allocator directly (= bypasses the overridden Class#new,
     avoiding infinite recursion); rb_obj_call_init_kw dispatches to
     #initialize forwarding the kwargs hash (= Ruby 3.x strict kwarg
     separation requires the _kw variant when passing through). */
  obj = rb_obj_alloc(klass);
  rb_obj_call_init_kw(obj, argc, argv, RB_PASS_CALLED_KEYWORDS);

  /* Single element or non-Face: no lift, return raw. */
  if ( !all_face || n < 2 ) return obj;

  /* Homogeneous Face: portable + pairwise state-compatible checks,
     then ca_face_lift to re-wrap as the same Face class. */
  if ( !ca_face_state_portable(ref_face->obj_type, face_class) ) {
    rb_raise(rb_eArgError,
             "CAStack.new: %s state is not portable across multiple "
             "parents (= per-parent storage like CAConstString's buffer); "
             "strip Face with .parent if a storage-level CAStack is intended",
             rb_class2name(face_class));
  }
  for ( i = 1; i < n; i++ ) {
    VALUE p = rb_ary_entry(list, i);
    CArray *ca;
    TypedData_Get_Struct(p, CArray, &carray_data_type, ca);
    if ( !ca_face_state_compatible(rb_ary_entry(list, 0), ref_face,
                                   p, ca) ) {
      rb_raise(rb_eArgError,
               "CAStack.new: Face state mismatch across parents "
               "(= %s instance at index %ld differs in state from index 0)",
               rb_class2name(face_class), i);
    }
  }
  return ca_face_lift(obj, rb_ary_entry(list, 0));
}

/* Public Ruby accessor: stack.n_parents → K */
static VALUE
rb_ca_stack_n_parents (VALUE self)
{
  CAStack *ca = (CAStack *) DATA_PTR(self);
  return INT2NUM(ca->n_parents);
}

/* Public Ruby accessor: stack.parents → Array of parent CArrays
   ([[project_view_hierarchy_introspectability]]). */
static VALUE
rb_ca_stack_parents (VALUE self)
{
  return rb_ivar_get(self, id_parents);
}

/* Public Ruby accessor: stack.k_axis → K axis insertion position [0, parent_ndim]. */
static VALUE
rb_ca_stack_k_axis (VALUE self)
{
  CAStack *ca = (CAStack *) DATA_PTR(self);
  return INT2NUM((int) ca->k_axis);
}

void
Init_ca_obj_stack (void)
{
  /* CAStack must match the CAMultiParent layout convention so generic code
     can fold over parents[] via the CA_FLAG_MULTI_PARENTS path. */
  if ( offsetof(CAStack, n_parents) != offsetof(CAMultiParent, n_parents) ||
       offsetof(CAStack, parents)   != offsetof(CAMultiParent, parents) ) {
    rb_raise(rb_eRuntimeError,
             "CAStack/CAMultiParent layout mismatch (build error)");
  }

  rb_cCAStack     = rb_define_class("CAStack", rb_cCAView);
  rb_cCAStackMask = rb_define_class("CAStackMask", rb_cCAStack);

  CA_OBJ_STACK = ca_install_obj_type(rb_cCAStack,
                                     &castack_data_type,
                                     rb_cCAStackMask,
                                     &castack_mask_data_type, &ca_stack_func, sizeof(ca_stack_func));
  rb_define_const(rb_cObject, "CA_OBJ_STACK", INT2NUM(CA_OBJ_STACK));

  id_parents = rb_intern("parents");

  /* CArray.stack / CArray#stack / CAStack#append are defined in Ruby
     (lib/carray/compose.rb).  CAStack.new is C-side: the allocator +
     #initialize handle the raw build, and rb_ca_stack_s_new overrides
     Class#new to layer Face-aware lift on top. */

  rb_define_alloc_func(rb_cCAStack, rb_ca_stack_s_allocate);
  rb_define_singleton_method(rb_cCAStack, "new", rb_ca_stack_s_new, -1);
  rb_define_method(rb_cCAStack, "initialize",
                                      rb_ca_stack_initialize, -1);
  rb_define_method(rb_cCAStack, "initialize_copy",
                                      rb_ca_stack_initialize_copy, 1);

  rb_define_method(rb_cCAStack, "n_parents", rb_ca_stack_n_parents, 0);
  rb_define_method(rb_cCAStack, "parents",   rb_ca_stack_parents,   0);
  rb_define_method(rb_cCAStack, "k_axis",    rb_ca_stack_k_axis,    0);
}
